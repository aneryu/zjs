# 17 — 标准全局安装与 NativeEntry 分发

本册讲 realm 怎么被 `standard_globals` 装满，以及 VM 如何通过 `NativeEntry` 打到内建实现。

**Realm 安装**：`installStandardGlobals` 是唯一安装器。它把 `rt.internal_builtins` 接到编译期 `internal_builtins.table`（按 `NativeBuiltinDomain` 分槽），按 QuickJS 顺序创建 Object.prototype / Function.prototype / 其余构造器，并用 AUTOINIT 推迟 ~700 个方法对象的物化。每个可分发方法在 comptime 就盖上 `(domain, id)`；热路径 `nativeMethodFastDispatch` 用这个整数查表，而不是按名字线性扫。

**NativeEntry 映射**：`InternalEntry`（名字、length、id、cproto、函数指针）经 `native_legacy.entryFromInternal` 变成不可变 `NativeEntry`。调用时 `invokeEntry` 按 `kind`（managed / leaf / method_leaf / getter / constructor…）选原型。realm 不进记录本身，而在栈上 `NativeCallEnvironment`；handler 用 `nativeCall()` 取回。真 `C_FUNCTION` 切到它的构造 realm（qjs `p->u.cfunc.realm`）。

Array/String 等已在 15 册；Promise/模块在 16 册。本册后半的 glue 是跨 domain 的薄转发。



## `src/exec/standard_globals.zig` — realm 标准全局安装

本文件是 realm 的 JS 可见面：构造器、命名空间、原型、方法表。实现体在各 `*_ops.zig`；这里只负责安装顺序与 AUTOINIT 描述符。

安装入口链：

1. `registerStandardGlobalsDefault` / `configureRuntime` 把回调写进 core Runtime。
2. `installStandardGlobals` 把 `rt.internal_builtins` 指到 `internal_builtins.table`。
3. `installStandardConstructors` 按 QuickJS 顺序造 Object.prototype → Function.prototype → 其余构造器。
4. 可分发的构造器对象（Object / Symbol / Boolean / String / RegExp / Date / ArrayBuffer / SharedArrayBuffer / DOMException）经 `setNativeBuiltinIdAndRecord` 拿到 `(domain, id)`，热路径才能 `nativeMethodFastDispatch`。
5. Math/JSON/Reflect/Atomics 是 AUTOINIT 命名空间，首次 get 才 `materializeBuiltinNamespaceAutoInit`。

`preparedMethods` 是编译期门：标准方法要么有内部记录，要么出现在 `native_record_debt`（eval / host domain / typed_array marker / name cascade 债务）。

### 类型

- `Flags`：writable/enumerable/configurable 三件套，bootstrap 用的局部子集。
- `Method`：就是 `core.property.AutoInit`；地址直接放进两字 AUTOINIT 槽。
- `MethodTableKind`：每张函数表的种类，决定 id 怎么填、marker 怎么盖。
- `NoRecordReason` / `native_record_debt`：允许没有可分发记录的白名单。
- `ConstructorKind`：全部标准构造器的枚举，兼作 `constructors[]` 结果数组的下标；真正的安装顺序由 `installStandardConstructors` 逐条写出，与枚举顺序并不相同。
- `NativeFunctionMetadata` / `NativeFunctionTag`：装完函数后盖上的 array marker、collection owner class、disposable 方法号。
- `Intrinsics`：测试用「造 Runtime + Context + 装全局」手柄。


### `setRequiredMethodNativeBuiltinId` (`src/exec/standard_globals.zig:93`)

- **签名**：`fn setRequiredMethodNativeBuiltinId( method: *Method, domain: core.function.NativeBuiltinDomain, id: ?u32, ) void`。
- **作用**：给标准方法槽写入强制 native-builtin id；缺 id 则 comptime 失败。
- **实现**：`id` 为空直接 `@compileError`；否则用 `core.function.nativeBuiltinId(domain, id)` 写进 `method.native_builtin_id`，再 `decodeNativeBuiltinId` 回读并断言 domain/id 一致。
- **所有权 / 错误 / 调用**：纯 comptime，不分配。

### `setOptionalMethodNativeBuiltinId` (`src/exec/standard_globals.zig:105`)

- **签名**：`fn setOptionalMethodNativeBuiltinId( method: *Method, domain: core.function.NativeBuiltinDomain, id: ?u32, ) void`。
- **作用**：有 id 才写入方法槽的 native-builtin id。
- **实现**：有 id 才编码写入；没有就保持 0，由 marker 或名字级联负责分发。
- **所有权 / 错误 / 调用**：纯 comptime，不分配。

### `isStringPrototypeNameDispatchMethod` (`src/exec/standard_globals.zig:113`)

- **签名**：`fn isStringPrototypeNameDispatchMethod(name: []const u8) bool`。
- **作用**：判断某个 String.prototype 方法名是否属于「允许没有 `.string` 记录 id」的那批：toString/valueOf 与 HTML 方法族加 substr。
- **实现**：一串 `std.mem.eql` 或链，命中返回 true，否则 false。`preparedMethods` 的 `.string_prototype` 臂用它决定是否放行没有 id 的条目。
- **所有权 / 错误 / 调用**：纯 comptime 谓词。

### `comptimeInternalRecordExists` (`src/exec/standard_globals.zig:160`)

- **签名**：`fn comptimeInternalRecordExists(comptime encoded_id: i32) bool`。
- **作用**：`JSRuntime.internalBuiltinRecord` 的 comptime 镜像：某个编码 id 在 `internal_builtins.table` 里到底有没有可分发记录。
- **实现**：`decodeNativeBuiltinId` 失败或 domain 下标越界返回 false；否则 `records.get(native_ref.id) != null`。
- **所有权 / 错误 / 调用**：纯 comptime。native-record 门（正反两向）都靠它。

### `noRecordReason` (`src/exec/standard_globals.zig:264`)

- **签名**：`fn noRecordReason(comptime table_kind: MethodTableKind, comptime name: []const u8) ?NoRecordReason`。
- **作用**：在 `native_record_debt` 白名单里按（表种类, 方法名）查「允许没有记录」的理由。
- **实现**：线性扫 `native_record_debt`，`table` 与 `name` 都相等则返回该行 `reason`，否则 null。
- **所有权 / 错误 / 调用**：纯 comptime。

### `preparedMethods` (`src/exec/standard_globals.zig:274`)

- **签名**：`fn preparedMethods(comptime source: anytype, comptime table_kind: MethodTableKind) @TypeOf(source)`。
- **作用**：comptime 把方法表填上 native-builtin id / marker，并强制「无记录必须进 `native_record_debt`」。
- **实现**：按 `MethodTableKind` 给每条 Method 调 `setRequiredMethodNativeBuiltinId` 或写 marker（typed_array、disposable_stack、array iterator kind、collection owner class）。随后若 `native_function` 且 `comptimeInternalRecordExists` 为假、又不在债务表，`@compileError`。反向债务表腐烂检查在文件末 comptime 块。
- **所有权 / 错误 / 调用**：纯 comptime。热路径 `nativeMethodFastDispatch` 依赖这里盖上的 id。

### `preparedMethod` (`src/exec/standard_globals.zig:508`)

- **签名**：`fn preparedMethod(comptime source: Method, comptime table_kind: MethodTableKind) Method`。
- **作用**：`preparedMethods` 的单条形式，给不在函数表里、单独声明的 AUTOINIT 描述符用。
- **实现**：把 source 包成一元数组调 `preparedMethods`，取 `[0]`。
- **所有权 / 错误 / 调用**：纯 comptime。`standalone_auto_init` 那批描述符靠它进同一道门。

### `standardStringAutoInitDescriptor` (`src/exec/standard_globals.zig:593`)

- **签名**：`fn standardStringAutoInitDescriptor(bytes: []const u8) ?*const core.property.AutoInit`。
- **作用**：按字节串在 `standard_string_auto_init` 表里找 `.string_constant` AUTOINIT 描述符。
- **实现**：线性 `std.mem.eql`，命中返回该条目的指针，未命中 null。
- **所有权 / 错误 / 调用**：返回的是静态表元素的借用指针。

### `constructorClassPrototypeId` (`src/exec/standard_globals.zig:661`)

- **签名**：`fn constructorClassPrototypeId(kind: ConstructorKind) ?core.ClassId`。
- **作用**：把 `ConstructorKind` 映射到 realm `class_proto` 槽的 `ClassId`（对标 qjs `JS_NewCConstructor` 写 `ctx->class_proto[]`）。
- **实现**：按 `kind` 分支。native Error 子类走 qjs 的 `native_error_proto[]` 家族、抽象 `%TypedArray%` 与 Proxy 没有自己的实例 class，这些返回 null。
- **所有权 / 错误 / 调用**：纯查表，无分配、无所有权。

### `temporaryStringAtom` (`src/exec/standard_globals.zig:744`)

- **签名**：`fn temporaryStringAtom(rt: *core.JSRuntime, name: []const u8) !core.Atom`。
- **作用**：把 bootstrap 表里的名字切片变成属性键 atom。
- **实现**：`core.atom.predefinedId(name, .string)` 命中就直接返回常量 id（tracer 不用管）；否则 `rt.internAtom` 并 `rt.atoms.pinForHost` 显式钉住（TGC S3 §4 class B 的显式 pin）。
- **所有权 / 错误 / 调用**：非预定义的 atom 必须由调用方用 `freeTemporaryStringAtom` 解钉，约 25 个调用点都是 `defer` 成对。

### `freeTemporaryStringAtom` (`src/exec/standard_globals.zig:751`)

- **签名**：`fn freeTemporaryStringAtom(rt: *core.JSRuntime, atom_id: core.Atom) void`。
- **作用**：释放 `temporaryStringAtom` 为非预定义名字打的显式 pin。
- **实现**：const atom 或 tagged int 直接返回；否则 `rt.atoms.unpinForHost`。
- **所有权 / 错误 / 调用**：与 `temporaryStringAtom` 成对。

### `createBuiltinAsciiStringValue` (`src/exec/standard_globals.zig:756`)

- **签名**：`fn createBuiltinAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：分配并初始化一个引擎对象或字符串值。
- **实现**：`bytes.len == 0` 时走 `rt.emptyString()` 拿 runtime 缓存的空串并返回它的 `value()`；否则 `core.string.String.createAscii(rt, bytes)` 新建一个 ASCII 字符串再取 `value()`。没有第三条分支，也不处理非 ASCII 字节。
- **所有权 / 错误 / 调用**：空串分支返回 runtime 单例的借用值（不新分配、不 retain）；非空分支返回新建字符串的值，写进属性槽后由 GC 接管。错误集只有 `String.createAscii` / `emptyString` 的 `error.OutOfMemory`，整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 树内唯一调用方：`defineConstructor`（`src/exec/standard_globals.zig:1351`）给 `String.prototype` 的 object-data 槽填 `""`。

### `defineData` (`src/exec/standard_globals.zig:765`)

- **签名**：`pub fn defineData( rt: *core.JSRuntime, target: *core.Object, name: []const u8, value: core.JSValue, flags: Flags, ) !void`。
- **作用**：用字符串名字在 `target` 上定义一条普通数据属性，走完整的 `defineOwnProperty`（会查重、允许覆盖同名属性）；是安装路径里最通用、也最慢的一条定义入口。
- **实现**：`temporaryStringAtom(rt, name)` 把名字转成 atom（预定义名直接命中 id，其余 intern 后 `pinForHost`，`defer freeTemporaryStringAtom` 归还），再 `target.defineOwnProperty(rt, key, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable))`。
- **所有权 / 错误 / 调用**：唯一的所有权动作是 `temporaryStringAtom` 对非预定义名字打的 host pin，`defer freeTemporaryStringAtom` 在本函数内成对归还；`value` 只是借用地写进描述符，属性表建立 GC 边后所有权归对象。错误集由 `internAtom` / `defineOwnProperty` 推断（`error.OutOfMemory` 为主）。原先唯一的调用方是零调用方的 `defineNativeMethod`，随它一并删除后本函数**树内已无调用点**，作为 `pub` 安装入口留给嵌入方。⚠️ `src/core/promise.zig:152` 与 `src/exec/construct.zig:300` 调的是那两个文件各自的同名局部函数（`promise.zig:243` / `construct.zig:555`），不是这一个；core 也不可能依赖 exec。

### `defineDataAssumingNew` (`src/exec/standard_globals.zig:783`)

- **签名**：`pub fn defineDataAssumingNew( rt: *core.JSRuntime, target: *core.Object, name: []const u8, value: core.JSValue, flags: Flags, ) !void`。
- **作用**：`defineData` 的快路径孪生：同样按名字装数据属性，但要求 `target` 是刚建好的 ordinary 对象且该名字尚未存在，用于 bootstrap 里一次性铺属性。
- **实现**：取 atom 的方式与 `defineData` 完全相同，只把写入换成 `target.defineOwnPropertyAssumingNew`，从而跳过 `defineOwnProperty` 里的 O(n) 重名扫描。前置条件（非 exotic、非 array / regexp / mapped-arguments、名字未占用）由调用方保证，函数内不校验；文档注释指向 `Object.defineOwnPropertyAssumingNew` 的完整条件表。
- **所有权 / 错误 / 调用**：与 `defineData` 同一套 atom pin/unpin 配对，写入换成 `defineOwnPropertyAssumingNew`，无额外分配。前置条件不校验，违反了是静默的属性表重复而非 error。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 调用方全在本文件：`defineConstructor`（1393，把构造器挂上 global）、`defineWellKnownSymbol`（2697）、`installDOMExceptionExtras`（3224/3225）。

### `defineDataAtom` (`src/exec/standard_globals.zig:795`)

- **签名**：`pub fn defineDataAtom( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, value: core.JSValue, flags: Flags, ) !void`。
- **作用**：调用方已经持有 atom 时的数据属性定义，省掉 intern 与 pin/unpin 两步；`Math` 的 8 个常量、`String.prototype.length` 这类固定键走它。
- **实现**：单行 `target.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable))`，没有任何 atom 生命周期动作——atom 的所有权留在调用方。
- **所有权 / 错误 / 调用**：不 intern、不 pin：atom 的生命周期完全归调用方（调用点传的都是 `core.atom.ids.*` 预定义常量 id）。错误只来自 `defineOwnProperty`（`error.OutOfMemory`）。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 调用方：`installMathConstants`（`src/exec/standard_globals.zig:1870-1877` 共 8 条常量）、`defineConstructor`（1379，给 Array 原型补 `constructor`）、`installStringPrototypeAliases`（2963，`String.prototype.length`）。

### `defineDataAtomAssumingNew` (`src/exec/standard_globals.zig:805`)

- **签名**：`pub fn defineDataAtomAssumingNew( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, value: core.JSValue, flags: Flags, ) !void`。
- **作用**：atom 键 + 跳过查重的数据属性定义，四个 define 变体里最省的一条；`BYTES_PER_ELEMENT` 这种「刚 reserve 完立刻写入」的常量走它。
- **实现**：单行 `target.defineOwnPropertyAssumingNew(rt, atom_id, core.Descriptor.data(...))`：既不 intern 也不扫描重名，两项前置条件（新建的 plain 对象、键未占用）都由调用方负责。
- **所有权 / 错误 / 调用**：四个 define 变体里唯一既不 intern 也不查重的，没有任何所有权动作。错误同上，只有分配失败。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 调用方 6 处全在本文件：`defineConstructor`（1381/1385 写 `constructor` 与 `prototype`）、`installStandardConstructorWithPrototype`（1594，`Error.stackTraceLimit`）、`installNumberConstants`（1793）、`installTypedArrayElementSize`（1984）、`installTypedArrayConstructorElementSize`（1990）。

### `defineStringConstantAtomAssumingNewWithRealm` (`src/exec/standard_globals.zig:815`)

- **签名**：`fn defineStringConstantAtomAssumingNewWithRealm( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, bytes: []const u8, flags: Flags, realm_global: ?*core.Object, ) !void`。
- **作用**：把一条「取值是固定 ASCII 字符串」的属性装成 AUTOINIT 占位——所有 `@@toStringTag`（"Symbol"、"Map"、"ArrayBuffer"、"Math"…）都走这里，字符串对象直到第一次读该属性才建。
- **实现**：先把本地 `Flags` 翻成 `core.property.Flags.data` 的 packed 表示；再用 `standardStringAutoInitDescriptor(bytes)` 在静态表 `standard_string_auto_init` 里按串内容线性查出预烘焙的 `core.property.AutoInit`——查不到即 `error.InvalidBuiltinRegistry`，也就是只允许表里登记过的常量串；最后 `target.defineAutoInitPropertyFromDescriptor(rt, atom_id, flags, realm_global, info)` 写入两字长的 AUTOINIT 槽。
- **所有权 / 错误 / 调用**：不建字符串对象：`info` 是 `standard_string_auto_init` 静态表元素的借用指针，直接存进 AUTOINIT 槽，字符串到首次读属性才由 AUTOINIT 物化。`realm_global` 也是借用。除了 `defineAutoInitPropertyFromDescriptor` 的分配失败，本函数自己会 `return error.InvalidBuiltinRegistry`（常量串未登记在静态表里）。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 调用方 8 处全在本文件，绝大多数是 `@@toStringTag`：`defineConstructor`（1358/1359 写 Error 原型的 name/message）、`installSymbolExtras`（2672）、`installCollectionPrototypeSymbols`（3151）等。

### `defineAccessorAtom` (`src/exec/standard_globals.zig:828`)

- **签名**：`pub fn defineAccessorAtom( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, getter: core.JSValue, setter: core.JSValue, flags: Flags, ) !void`。
- **作用**：按 atom 写入一条 getter/setter 访问器属性；setter 传 undefined 即只读访问器。
- **实现**：显式 `_ = flags.writable;` 丢弃 writable（访问器描述符里没有这一位），随后 `target.defineOwnProperty(rt, atom_id, core.Descriptor.accessor(getter, setter, flags.enumerable, flags.configurable))`。走的是查重版 `defineOwnProperty`，因此允许把已存在的键改成访问器。
- **所有权 / 错误 / 调用**：不分配、不 pin，`getter`/`setter` 两个函数对象值由调用方刚建好并直接交给描述符，属性表接管 GC 边。错误只有 `defineOwnProperty` 的分配失败。虽然是 `pub`，树内只有本文件两个调用方：`defineLazyNativeGetterAtomWithRealmAndMetadata`（`src/exec/standard_globals.zig:915`，setter 位填 undefined）与 `defineLazyNativeAccessorPairAtom`（939）。

### `applyNativeFunctionMetadata` (`src/exec/standard_globals.zig:853`)

- **签名**：`fn applyNativeFunctionMetadata( rt: *core.JSRuntime, value: core.JSValue, metadata: NativeFunctionMetadata, ) !void`。
- **作用**：给刚造出来的 native 函数对象盖上元数据：native-builtin 记录 id，以及可选的 array marker / collection owner class / disposable-stack 方法号。
- **实现**：先要求 `value.isObject()`，否则 `error.InvalidBuiltinRegistry`；`expectObjectAssumeBootstrap` 无检查地取出对象。`metadata.native_builtin_id != 0` 时 `setNativeBuiltinIdAndRecord` 盖 id 并顺带解析出 `NativeEntry`。随后按 `metadata.tag` 五路分支求一个 `valid: bool`：`.none` 恒 true，其余四路分别 `addArrayBuiltinMarker` / `addCollectionMethodOwnerClass` / `addDisposableStackMethod` / `addAsyncDisposableStackMethod`（这四个都返回 bool，槽位已被别的标记占用时返回 false）。`valid` 为假统一 `return error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：只在既有函数对象上写标记位，不分配、不建根；`value` 是调用方刚用 `nativeFunction` 建的，所有权不转移。错误：`error.InvalidBuiltinRegistry`（非对象 / 标记槽冲突）+ `add*Marker` 内部的 `error.OutOfMemory`。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 树内唯一调用方：`defineLazyNativeGetterAtomWithRealmAndMetadata`（`src/exec/standard_globals.zig:914`）。

### `defineLazyNativeGetterAtom` (`src/exec/standard_globals.zig:873`)

- **签名**：`fn defineLazyNativeGetterAtom( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, getter_name: []const u8, getter_native_builtin_id: i32, flags: Flags, ) !void`。
- **作用**：装一个只读 native getter，且不指定 realm——用于 target 自身就能定出 realm 的场合（`RegExp` / `Promise` / `Map` / `ArrayBuffer` 构造器上的 `[Symbol.species]`）。
- **实现**：纯转发 `defineLazyNativeGetterAtomWithRealm`，`realm_global` 传 `null`，realm 交给 `bootstrapPropertyRealm` 从 `target` 自身的 native-function realm 推。
- **所有权 / 错误 / 调用**：纯转发，自身无所有权动作；错误与分配全在被转发的 `defineLazyNativeGetterAtomWithRealmAndMetadata` 里。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 5 个调用方全在本文件，都是构造器上的 `[Symbol.species]`：`installPromiseExtras`（2916）、`installRegExpExtras`（3037）、`installCollectionSpecies`（3125）、`installTypedArraySpecies`（3131），以及 buffer 构造器的 2823。

### `defineLazyNativeGetterAtomWithRealm` (`src/exec/standard_globals.zig:884`)

- **签名**：`fn defineLazyNativeGetterAtomWithRealm( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, getter_name: []const u8, getter_native_builtin_id: i32, flags: Flags, realm_global: ?*core.Object, ) !void`。
- **作用**：带显式 realm global 的只读 native getter 定义入口：TypedArray 原型的 `buffer`/`byteLength`/`byteOffset`/`length`、RegExp 的 10 个 flag 访问器、`Symbol.prototype.description` 都从这里进。
- **实现**：把 `getter_native_builtin_id` 包成 `NativeFunctionMetadata{ .native_builtin_id = ... }`（`tag` 留 `.none`）后转 `defineLazyNativeGetterAtomWithRealmAndMetadata`，自身不碰对象。
- **所有权 / 错误 / 调用**：只做参数打包，不分配、不持有 `realm_global`（借用）。错误同被转发者。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 8 个调用方全在本文件：`defineLazyNativeGetterAtom`（880）、`installTypedArrayPrototypeAccessors`（2025/2032）、`installSymbolExtras`（2667）、`installRegExpExtras`（3034）、`defineRegExpLegacyAccessor`（3101）等。

### `defineLazyNativeGetterAtomWithRealmAndMetadata` (`src/exec/standard_globals.zig:904`)

- **签名**：`fn defineLazyNativeGetterAtomWithRealmAndMetadata( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, getter_name: []const u8, metadata: NativeFunctionMetadata, flags: Flags, realm_global: ?*core.Object, ) !void`。
- **作用**：只读 native 访问器的真正构造点：建 getter 函数对象、盖上 native 记录 id 与可选的分类标记，再写成 `{get, undefined}` 的访问器属性。
- **实现**：`bootstrapPropertyRealm` 解析 realm（显式 global 优先，其次 target 自身的 native / bytecode realm，最后把 target 当 global 查）；`core.function.nativeFunction(realm, getter_name, 0)` 建 length 0 的函数对象——注意函数体是**立刻**建的，名字里的 “Lazy” 只指属性值的求值推迟到 getter 被调用，与 `defineNativeMethodsAssumingNew` 的 AUTOINIT 占位不是一回事；`applyNativeFunctionMetadata` 盖 `native_builtin_id` 并按 tag 追加 array-builtin marker / collection owner class / (Async)DisposableStack method id，任一步返回 false 即 `error.InvalidBuiltinRegistry`；最后 `defineAccessorAtom`，setter 位填 `undefined`。
- **所有权 / 错误 / 调用**：会真分配一个 getter 函数对象（`core.function.nativeFunction`），但它在同一条语句里就被 `defineAccessorAtom` 写进属性表、由对象接管，中间没有安全点，因此没有建 `ValueRootFrame`；`realm` 与 `realm_global` 都是借用指针。错误：`bootstrapPropertyRealm` / `applyNativeFunctionMetadata` 的 `error.InvalidBuiltinRegistry` + 各处 `error.OutOfMemory`。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 4 个调用方全在本文件：`defineLazyNativeGetterAtomWithRealm`（892）、`defineCollectionSizeAccessorAssumingNew`（1916）、`installArrayPrototypeSymbols`（2707）、`installDisposableStackCtorExtras`（3204）。

### `defineLazyNativeAccessorPairAtom` (`src/exec/standard_globals.zig:919`)

- **签名**：`fn defineLazyNativeAccessorPairAtom( rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, getter_name: []const u8, getter_native_builtin_id: i32, setter_length: i32, setter_native_builtin_id: i32, flags: Flags, realm_global: ?*core.Object, ) !void`。
- **作用**：一次装齐 getter 与 setter 的 native 访问器对：`Error.prototype.stack`、`Object.prototype.__proto__`、`Iterator.prototype.constructor` / `@@toStringTag`、RegExp 的 `input` / `$_` 都是它装的。
- **实现**：解析 realm 后建 length 0 的 getter，`getter_native_builtin_id != 0` 时 `setNativeBuiltinIdAndRecord`；随后强制 `getter_name` 以 `"get "` 开头（否则 `error.InvalidBuiltinRegistry`），把其余部分拼成 `"set X"` 写进 128 字节栈缓冲，`bufPrint` 溢出同样报 `InvalidBuiltinRegistry`；以 `setter_length`（所有调用点都传 1）建 setter 并按同样条件盖 id；最后一次 `defineAccessorAtom` 写入两半。
- **所有权 / 错误 / 调用**：分配两个函数对象（getter + setter），同样直接交给 `defineAccessorAtom`，不登记 GC 根；`setter_name_buf` 是 128 字节**栈**缓冲，不需要释放（这是本册里少数真有局部缓冲的函数）。错误：`error.InvalidBuiltinRegistry`（getter 名不以 `"get "` 开头、或拼 setter 名溢出 128 字节）+ 分配失败。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 5 个调用方全在本文件：`installErrorPrototypeExtras`（2900，`Error.prototype.stack`）、`installIteratorExtras`（2935/2947）、`defineObjectPrototypeMethodsAssumingNew`（2974，`__proto__`）、`defineRegExpLegacyAccessor`（3089）。

### `bootstrapPropertyRealm` (`src/exec/standard_globals.zig:943`)

- **签名**：`fn bootstrapPropertyRealm(rt: *core.JSRuntime, target: *core.Object, explicit_global: ?*core.Object) !*core.RealmContext`。
- **作用**：解析在 bootstrap 上定义属性时该用哪个 `RealmContext`。
- **实现**：给了 `explicit_global` 就 `rt.contextForGlobalIncludingConstructing`；否则依次试 `target.nativeFunctionRealm()`、`target.bytecodeFunctionRealmContext()`，最后把 `target` 自己当 global 查；全失败 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：返回借用的 realm 指针。几乎所有 define* 安装函数都先过这里。

### `defineNativeMethodsAssumingNew` (`src/exec/standard_globals.zig:966`)

- **签名**：`pub fn defineNativeMethodsAssumingNew(rt: *core.JSRuntime, target: *core.Object, methods: []const Method) !void`。
- **作用**：在全新普通对象上批量安装 AUTOINIT 方法占位（installStandardGlobals 的主要加速点）。本文件原先还有一对零调用方的即时安装版 `defineNativeMethod` / `defineNativeMethods`，已删除。
- **实现**：转 `defineNativeMethodsAssumingNewWithRealm`：把 Flags 译成 property.Flags，预留容量，解析 bootstrap realm，对每条 method intern atom 后 `defineAutoInitPropertyFromDescriptorWithResolvedRealm`。
- **所有权 / 错误 / 调用**：纯转发（`realm_global` 传 null）。调用方保证对象新鲜、名字不重复；真正的 native 函数对象推迟到首次 get 才建。错误与所有权见 `defineNativeMethodsAssumingNewWithRealm`。调用方：`installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1544`）、`defineConstructor`（1364）、`installUint8ArrayConstructorCodecExtras`（1994）。

### `defineNativeMethodsAssumingNewWithRealm` (`src/exec/standard_globals.zig:970`)

- **签名**：`fn defineNativeMethodsAssumingNewWithRealm(rt: *core.JSRuntime, target: *core.Object, methods: []const Method, realm_global: ?*core.Object) !void`。
- **作用**：`defineNativeMethodsAssumingNew` 的实现体，多带一个显式 realm global。
- **实现**：先把本地 `method_flags` 译成 `core.property.Flags.data` 的 packed 表示。`methods.len != 0` 时按 `shape_ref.prop_count + methods.len` 一次性 `reserveOwnPropertyCapacityAssumingPlain`（空表直接返回，省掉 realm 解析）。随后 `bootstrapPropertyRealm` 解析一次 realm 并在整个循环里复用（这就是 `WithResolvedRealm` 后缀的意义）；对每条 method 用 `temporaryStringAtom` 取键、`defer` 归还，再 `defineAutoInitPropertyFromDescriptorWithResolvedRealm(rt, key, flags, realm, method)` 把 `*const Method` 的地址直接塞进两字 AUTOINIT 槽——函数对象一个都不建。
- **所有权 / 错误 / 调用**：每轮 atom 的 host pin 在轮内 `defer` 归还；写进槽里的是 `methods` 元素的**静态地址**，所以 `methods` 必须是 comptime 常量表（本文件的 `preparedMethods` 结果都满足）而不能是临时切片。不分配函数对象、不建 GC 根。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 8 个调用方全在本文件：`defineNativeMethodsAssumingNew`（982）、`defineConstructor`（1346）、`createNamespaceObject`（1068）、`installTypedArrayIntrinsicExtras`（1826）、`defineCollectionPrototypeMethodsAssumingNew`（1901-1909）等。

### `defineGlobalLazyMethods` (`src/exec/standard_globals.zig:985`)

- **签名**：`fn defineGlobalLazyMethods(rt: *core.JSRuntime, global: *core.Object, methods: []const Method) !void`。
- **作用**：用 global 属性 flags（可写、不可枚举、可配置）在 global 上批量装 AUTOINIT 方法占位。
- **实现**：与 `defineNativeMethodsAssumingNewWithRealm` 同形，但用 `global_flags`（可写、不可枚举、可配置）而不是 `method_flags`，且**不预留容量**——global 的容量在 `installStandardGlobals` 入口用 `standardGlobalOwnPropertyCapacity()` 一次性 reserve 过了。空表直接返回；否则以 `global` 自身为显式 realm global 解析一次 realm，逐条 `temporaryStringAtom` + `defineAutoInitPropertyFromDescriptorWithResolvedRealm`。
- **所有权 / 错误 / 调用**：所有权同上：atom pin 轮内配对，AUTOINIT 槽存 `methods` 元素静态地址。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 两个调用方都是 `installStandardGlobals`（`src/exec/standard_globals.zig:1753` 与 1756），拆成两段是为了在中间插 `installNumberParseAliases`，让 `parseInt`/`parseFloat` 先从 `Number` 上取到再发布到 global。

### `publishMethodAlias` (`src/exec/standard_globals.zig:996`)

- **签名**：`fn publishMethodAlias( rt: *core.JSRuntime, target: *core.Object, source: *core.Object, source_atom: core.Atom, alias_atom: core.Atom, replace_existing_auto_init: bool, ) !void`。
- **作用**：把 `source` 上 `source_atom` 的值原样发布到 `target` 的 `alias_atom`（方法别名，如 trimStart→trimLeft、values→@@iterator）。
- **实现**：`source.getProperty(source_atom)` 取值（会触发 AUTOINIT 物化），再交给 `publishMethodAliasValue`。
- **所有权 / 错误 / 调用**：`source.getProperty` 会触发 AUTOINIT 物化，返回的函数对象值原样转手给 `publishMethodAliasValue` 写入，别名与原名从此共享同一个函数对象（`expectNativeAliasForTest` 就是断言这一点）。自身不分配、不 pin。错误：`getProperty` 的 `PropertyReadError` + 写入的分配失败。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 8 个调用方全在本文件：`installNumberParseAliases`（1773）、`installTypedArrayIntrinsicExtras`（1829）、`installNativeMethodAlias`（3110）、`installCollectionPrototypeSymbols`（3142/3147/3148）等。

### `publishMethodAliasValue` (`src/exec/standard_globals.zig:1008`)

- **签名**：`fn publishMethodAliasValue( rt: *core.JSRuntime, target: *core.Object, alias_atom: core.Atom, value: core.JSValue, replace_existing_auto_init: bool, ) !void`。
- **作用**：用方法属性 flags 把一个已取到的值写进 `target[alias_atom]`。
- **实现**：`replace_existing_auto_init` 为真走 `target.replaceAutoInitPropertyWithData`（覆盖已存在的 AUTOINIT 占位），否则按全新属性 `defineOwnPropertyAssumingNew`。
- **所有权 / 错误 / 调用**：不分配；`value` 借用地写进描述符。两条分支的前置条件不同：`replaceAutoInitPropertyWithData` 要求该键**已存在**且是 AUTOINIT 槽，`defineOwnPropertyAssumingNew` 要求该键**不存在**——选错分支不会报错，只会写坏属性表。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 两个调用方都在本文件：`publishMethodAlias`（1020）与 `publishTypedArrayToStringAlias`（1049）。

### `publishTypedArrayToStringAlias` (`src/exec/standard_globals.zig:1027`)

- **签名**：`fn publishTypedArrayToStringAlias( rt: *core.JSRuntime, target: *core.Object, source: *core.Object, atom_id: core.Atom, ) !void`。
- **作用**：把 `Array.prototype.toString` 复制到 `%TypedArray%.prototype` 的同名槽，并给该函数对象补上 typed-array 原型 marker。
- **实现**：`source.getProperty` 取值后 `publishMethodAliasValue(..., true)` 覆盖占位。随后要求该值是对象、`arrayBuiltinMarker() == .to_string`，再 `addTypedArrayBuiltinMarker(.prototype_method)`；任一不满足返回 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：不分配新函数：`%TypedArray%.prototype.toString` 与 `Array.prototype.toString` 之后是同一个对象，因此这里给它补的 typed-array marker 也会被 Array 那侧看见——这是有意的（同一函数要同时认两种 receiver）。错误：`error.InvalidBuiltinRegistry`（取到的不是对象 / `arrayBuiltinMarker()` 不是 `.to_string` / marker 槽已被占）+ 分配失败。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 树内唯一调用方：`installTypedArrayIntrinsicExtras`（`src/exec/standard_globals.zig:1825`）。

### `createNamespaceObject` (`src/exec/standard_globals.zig:1044`)

- **签名**：`fn createNamespaceObject(rt: *core.JSRuntime, global: *core.Object, methods: []const Method, extra_property_count: usize) !*core.Object`。
- **作用**：造一个以 `Object.prototype` 为原型、按 `methods.len + extra_property_count` 预留容量的命名空间对象，并批量装 AUTOINIT 方法。
- **实现**：`core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global), methods.len + extra_property_count)` 建一个以 `Object.prototype` 为原型、容量一次到位的普通对象——`extra_property_count` 是留给之后要补的 `@@toStringTag`（1）和 Math 的 8 个常量的。随后 `defineNativeMethodsAssumingNewWithRealm(rt, namespace, methods, global)` 批量铺 AUTOINIT 方法占位，返回该对象指针（注意返回 `*core.Object` 而不是 `JSValue`）。
- **所有权 / 错误 / 调用**：返回**新建**的命名空间对象；在调用方 `materializeBuiltinNamespaceAutoInit` 把它 return 成属性值之前它没有任何引用者，但从建好到返回之间不再分配，所以没建 GC 根。错误：建对象 / 铺属性的 `error.OutOfMemory`。**与其余 install 家族不同，这条路径不只跑在 bootstrap**：它由 `materializeBuiltinNamespaceAutoInit`（`src/exec/standard_globals.zig:1087/1089/1090`，Math / Reflect / Atomics 三路）在首次读 `globalThis.Math` 之类时触发，错误经 `Object.materializeBuiltinNamespaceAutoInit`（`src/core/object.zig:8031`）的 `PropertyReadError` 变成一次属性读失败、进而成为 JS 异常。

### `defineLazyNamespace` (`src/exec/standard_globals.zig:1057`)

- **签名**：`fn defineLazyNamespace(rt: *core.JSRuntime, global: *core.Object, key: core.Atom, kind: core.property.AutoInitKind) !void`。
- **作用**：在 global 上把 `Math` / `JSON` / `Reflect` / `Atomics` 四个命名空间装成 AUTOINIT 占位，命名空间对象本身要到第一次读 `globalThis.Math` 之类时才建。
- **实现**：按 `kind` 从 `math_namespace_auto_init` / `json_namespace_auto_init` / `reflect_namespace_auto_init` / `atomics_namespace_auto_init` 四个静态描述符里选一个，其余 kind 直接 `error.InvalidBuiltinRegistry`；再核对 `core.atom.predefinedName(key)` 与 `info.name` 相等，防止 atom 与描述符错配；最后用 `global_flags`（可写、不可枚举、可配置）`global.defineAutoInitPropertyFromDescriptor`，realm global 就是 `global` 自身。物化端在 `materializeBuiltinNamespaceAutoInit`。
- **所有权 / 错误 / 调用**：不建命名空间对象，只写一个 AUTOINIT 槽，槽里存的是四个静态描述符之一的借用指针；`global` 同时当 target 和 realm global。错误：`error.InvalidBuiltinRegistry`（kind 不在四种之内、或 atom 名与描述符名对不上）+ 分配失败。整条 bootstrap install 家族的错误协议一致：错误集由 Zig 推断（实际只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），一路 `try` 上抛到 `installStandardGlobals`，再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`；失败时 `rollbackIntrinsicBootstrap` 回滚 realm、context 创建失败——**不经 `materializeRuntimeError`，也不会变成 JS 异常**。 四个调用方都是 `installStandardGlobals`（`src/exec/standard_globals.zig:1746-1749`），一 kind 一条。

### `materializeBuiltinNamespaceAutoInit` (`src/exec/standard_globals.zig:1070`)

- **签名**：`pub fn materializeBuiltinNamespaceAutoInit(rt: *core.JSRuntime, global: *core.Object, kind: core.property.AutoInitKind) !core.JSValue`。
- **作用**：AUTOINIT 命中时物化 Math/JSON/Reflect/Atomics 命名空间对象。
- **实现**：按 kind 造命名空间（JSON 走 `createJsonNamespaceObject`，其余 `createNamespaceObject`）。随后 Math 绑记录 + 装 8 个常量 + `@@toStringTag`；JSON 只写 `@@toStringTag`；Reflect / Atomics 绑记录并写 `@@toStringTag`。
- **所有权 / 错误 / 调用**：返回拥有的对象值。未知 kind `error.TypeError`。由 `rt.materialize_builtin_namespace_cb` 调用。

### `createJsonNamespaceObject` (`src/exec/standard_globals.zig:1100`)

- **签名**：`fn createJsonNamespaceObject(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：造 JSON 命名空间对象，并逐条装上 AUTOINIT 方法占位。
- **实现**：与 `createNamespaceObject` 同形但手写展开：`createWithOwnPropertyCapacity` 按 `json_methods.len + namespace_to_string_tag_property_count` 建对象，自己算 `core.property.Flags.data(method_flags...)`、自己 `bootstrapPropertyRealm(rt, namespace, global)` 解析一次 realm，再对 `&json_methods` 逐条 `temporaryStringAtom` + `defer freeTemporaryStringAtom` + `defineAutoInitPropertyFromDescriptorWithResolvedRealm`，返回对象指针。之所以不复用 `createNamespaceObject`，是因为 `json_methods` 需要按 `*const Method` 地址取（`for (&json_methods) |*method|`）而通用版收的是切片。
- **所有权 / 错误 / 调用**：返回新建对象；atom pin 轮内配对；AUTOINIT 槽存 `json_methods` 元素静态地址。错误只有分配失败与 `bootstrapPropertyRealm` 的 `error.InvalidBuiltinRegistry`。与 `createNamespaceObject` 一样跑在 AUTOINIT 物化路径上（唯一调用方 `materializeBuiltinNamespaceAutoInit`，`src/exec/standard_globals.zig:1088`），错误会成为一次 `globalThis.JSON` 读失败并抛 JS 异常，而不是 bootstrap 失败。

### `objectPrototypeFromGlobal` (`src/exec/standard_globals.zig:1117`)

- **签名**：`fn objectPrototypeFromGlobal(global: *core.Object) ?*core.Object`（原先恒被丢弃的 `rt` 形参已删）。
- **作用**：从 global 上的 `Object` 构造器借出 `Object.prototype`。
- **实现**：`getOwnDataObjectBorrowed("Object")` 再 `getOwnDataObjectBorrowed(prototype)`，任一缺失返回 null。
- **所有权 / 错误 / 调用**：返回借用指针，不加引用。

### `standardGlobalOwnPropertyCapacity` (`src/exec/standard_globals.zig:1131`)

- **签名**：`pub fn standardGlobalOwnPropertyCapacity() usize`。
- **作用**：预估标准 global 的自有属性数，供建 global 时一次性预留容量（同一个数也钉进 Runtime 回调）。
- **实现**：`constructor_kind_count` + 4（Math/JSON/Reflect/Atomics）+ 2（performance/navigator）+ `global_lazy_function_property_count`（15）。
- **所有权 / 错误 / 调用**：无：几个 comptime 常量相加，不分配、无 error set。调用方 5 处：`registerStandardGlobalsDefault`（`src/exec/standard_globals.zig:1456`）和 `configureRuntime`（1465）把它钉进 Runtime、`installStandardGlobals`（1738）据此 reserve global、`Intrinsics.init`（3267）建测试 global，以及 `src/exec/call.zig:64` 的 `hostGlobalOwnPropertyCapacity` 在它之上再加 6 个 CLI 全局。

### `constructorOwnPropertyCapacity` (`src/exec/standard_globals.zig:1138`)

- **签名**：`fn constructorOwnPropertyCapacity(kind: ConstructorKind, static_method_count: usize) usize`。
- **作用**：算一个构造器对象要预留多少自有属性槽。
- **实现**：2（length/name）+ 非 Proxy 的 1 个 `prototype` + 静态方法数 + `constructorExtraPropertyCount(kind)`。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1306`），结果直接喂给 `nativeFunctionWithPrototypeAndCapacity`；估小了只是后续 reserve 变多，不会出错。

### `prototypeOwnPropertyCapacity` (`src/exec/standard_globals.zig:1143`)

- **签名**：`fn prototypeOwnPropertyCapacity(kind: ConstructorKind, prototype_method_count: usize) usize`。
- **作用**：算一个原型对象要预留多少自有属性槽。
- **实现**：Proxy 返回 0；`.function` 额外 +2；再加原型方法数、1 个 `constructor`（Iterator 是 accessor）与 `prototypeExtraPropertyCount(kind)`。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 调用方 3 处全在本文件：`defineConstructor`（`src/exec/standard_globals.zig:1317`），以及 `installStandardConstructors` 里给 Object.prototype（1649）和 Function.prototype（1662）预建原型时各一次。

### `constructorExtraPropertyCount` (`src/exec/standard_globals.zig:1152`)

- **签名**：`fn constructorExtraPropertyCount(kind: ConstructorKind) usize`。
- **作用**：每个 kind 的构造器除 length/name/prototype 与静态方法之外还要装几条额外属性（Symbol 15 个 well-known symbol、Number 8 个常量、RegExp 的 `escape` + `[Symbol.species]` + 19 条 legacy accessor 共 21 条、DOMException 的 25 条常量等），供建构造器对象时一次性预留属性容量。
- **实现**：纯查表 switch：`.symbol` 15（well-known symbol 表）、`.regexp` 21（`escape` + `[Symbol.species]` + 19 条 legacy 静态访问器）、`.number` `number_constant_property_count` = 8、`.dom_exception` `dom_exception_constants.len` = 25、`.uint8_array` 3（`BYTES_PER_ELEMENT` + `fromBase64` / `fromHex`）；`.array`、`.error_`、`.promise`、`.map`、`.set`、`.array_buffer`、`.shared_array_buffer`、`.typed_array` 与另外 11 种具体 TypedArray 各 1；`.proxy` 与其余全部落 `else => 0`。返回值只用于构造器对象 `createWithOwnPropertyCapacity` 的预留量，少算不会出错、只会多一次 rehash。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 唯一调用方是上面的 `constructorOwnPropertyCapacity`（`src/exec/standard_globals.zig:1156`）。数字是人工对着安装代码数出来的，加属性时必须同步改，否则只影响容量估计不影响正确性。

### `prototypeExtraPropertyCount` (`src/exec/standard_globals.zig:1184`)

- **签名**：`fn prototypeExtraPropertyCount(kind: ConstructorKind) usize`。
- **作用**：每个 kind 的原型除方法表之外还要装几条额外属性（accessor、`@@toStringTag`、别名、常量等）。
- **实现**：同样是查表 switch，数字含义各不相同：`.string` 4（`length` + `trimLeft` / `trimRight` 别名 + `@@iterator`）、`.symbol` 3（`description` + `@@toPrimitive` + `@@toStringTag`）、`.regexp` 15、`.typed_array` 8、`.array_buffer` 6、`.uint8_array` 5、`.shared_array_buffer` / `.data_view` 4、`.map` / `.set` / `.disposable_stack` / `.async_disposable_stack` / `.iterator` / `.error_` 3、`.array` / `.date` 与八个 error 子类（AggregateError、SuppressedError 及六个 native error 加 `.internal_error`）2、`.object` / `.function` / `.bigint` / `.promise` / `.weak_ref` / `.finalization_registry` / `.weak_map` / `.weak_set` 与 11 种具体 TypedArray 1，`.dom_exception` 为 `1 + dom_exception_constants.len`，其余 0。调用方 `prototypeOwnPropertyCapacity` 会另加 `constructor` 一条与 Function.prototype 的 2 条，所以像 Iterator 的 `constructor` 访问器不重复计在这里。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 唯一调用方是 `prototypeOwnPropertyCapacity`（`src/exec/standard_globals.zig:1165`）。同样是人工对账的常量表。

### `constructorStaticMethodsBeforePrototype` (`src/exec/standard_globals.zig:1240`)

- **签名**：`fn constructorStaticMethodsBeforePrototype(kind: ConstructorKind) bool`。
- **作用**：该 kind 是否要在挂上 `.prototype` 之前先装静态方法（对标 qjs 先装 `JSCFunctionListEntry` 再 `JS_SetConstructor2` 的顺序）。
- **实现**：白名单 switch，13 个 kind 返回 true：`.object`、`.number`、`.symbol`、`.error_`、`.date`、`.array`、`.string`、`.bigint`、`.promise`、`.map`、`.array_buffer`、`.typed_array`、`.iterator`，其余 `else => false`。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 两个调用方是同一个判定的正反两面：`defineConstructor`（`src/exec/standard_globals.zig:1361`）在装 `.prototype` 之前装静态方法，`installStandardConstructorWithPrototype`（1544）在之后装——两处条件互补，保证每个构造器恰好装一次静态表。

### `prototypeMethodsAreInstalledByExtras` (`src/exec/standard_globals.zig:1260`)

- **签名**：`fn prototypeMethodsAreInstalledByExtras(kind: ConstructorKind) bool`。
- **作用**：该 kind 的原型方法由各自的 extras 安装器负责，`defineConstructor` 主路径要跳过（Map/Set/ArrayBuffer/SharedArrayBuffer/DataView）。
- **实现**：白名单 switch，只有 `.map`、`.set`、`.array_buffer`、`.shared_array_buffer`、`.data_view` 返回 true——前两者的原型方法由 `defineCollectionPrototypeMethodsAssumingNew` 装（要在中间插 `size` 访问器），后三者由 `installBufferConstructorExtras` 装（要在访问器之后）；其余 `else => false`。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1345`）：返回 true 的五个 kind（Map/Set/ArrayBuffer/SharedArrayBuffer/DataView）在这里跳过通用原型方法安装，改由各自的 `install*Extras` 装，漏一处就是原型空方法表。

### `defineConstructor` (`src/exec/standard_globals.zig:1272`)

- **签名**：`fn defineConstructor( rt: *core.JSRuntime, global: *core.Object, constructor_parent: *core.Object, prototype_parent: ?*core.Object, existing_prototype: ?*core.Object, name: []const u8, kind: ConstructorKind, length: i32, static_methods: []const Method, prototype_methods: []const Method, ) !core.JSValue`。
- **作用**：为一个 ConstructorKind 造构造器对象、原型、静态/原型方法，并挂到 global。
- **实现**：用 `nativeFunctionWithPrototypeAndCapacity` 造构造器。非 Proxy：按 kind 选 class 造原型（Array/String/Number/Boolean 用对应 class），装方法或走 extras。Error 原型写 name/message。部分 kind 先装静态再 `JS_SetConstructor2` 式地互指 prototype/constructor。最后 `defineDataAssumingNew` 把构造器放到 global。
- **所有权 / 错误 / 调用**：构造器本地 `live_constructor` 必须 root，因为 intern 可能触发 GC。bootstrap 保证名字不重复。

### `isErrorConstructorKind` (`src/exec/standard_globals.zig:1381`)

- **签名**：`fn isErrorConstructorKind(kind: ConstructorKind) bool`。
- **作用**：判断该 kind 是否属于 Error 家族（Error 本体、AggregateError/SuppressedError 与六个 native error 子类），决定原型上要不要写 name/message。
- **实现**：白名单 switch，10 个 kind 为 true：`.error_`、`.aggregate_error`、`.suppressed_error`，以及 `.eval_error` / `.range_error` / `.reference_error` / `.syntax_error` / `.type_error` / `.uri_error` / `.internal_error`；其余 false。与 `isNativeErrorSubclassKind` 的唯一差别是这里包含 `.error_` 本体。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1357`），用来决定要不要给原型补 `name` / `message` 两条字符串常量属性。注意它与 `isNativeErrorSubclassKind`（1833）差一个 `.error_`：这个包含基类 Error，那个不包含。

### `nativeErrorKind` (`src/exec/standard_globals.zig:1398`)

- **签名**：`fn nativeErrorKind(kind: ConstructorKind) ?core.context.NativeErrorKind`。
- **作用**：把 Error 家族的 `ConstructorKind` 映射到 `core.context.NativeErrorKind`，供 `realm.setNativeErrorPrototype` 使用；其余 kind 返回 null。
- **实现**：一对一映射 switch：上面那 10 个 kind 逐条映到同名的 `core.context.NativeErrorKind`（`.error_`→`.error_`、`.eval_error`→`.eval_error`、…、`.aggregate_error`→`.aggregate_error`、`.suppressed_error`→`.suppressed_error`），`else => null`。两个枚举成员名刻意保持一致，映射表里没有重命名。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1536`），命中时把原型写进 realm 的 `native_error_proto[]` 槽（`realm.setNativeErrorPrototype`）。

### `expectObjectAssumeBootstrap` (`src/exec/standard_globals.zig:1418`)

- **签名**：`fn expectObjectAssumeBootstrap(value: core.JSValue) *core.Object`。
- **作用**：bootstrap 专用的无检查解包：把安装器自己刚造出来的值取成 `*core.Object`。
- **实现**：`core.value_semantics.objectFromValue(value).?`。JS 来源的值不能走这里，要用 `core.value_semantics.expectObject`。
- **所有权 / 错误 / 调用**：无检查的解包：`objectFromValue(value).?`，非对象值会命中 `.?` 的 unreachable。返回借用指针，不加引用、不分配、无 error set。调用契约就是源码注释写的那句——只许传安装器自己刚造出来的对象，JS 来路的值要走 `core.value_semantics.expectObject`。本文件共 41 处调用方，非测试路径 11 处：`applyNativeFunctionMetadata`（858）、`defineLazyNativeAccessorPairAtom`（931/938）、`publishTypedArrayToStringAlias`（1052）、`defineConstructor`（1314/1332）、`installStandardConstructorWithPrototype`（1528）、`installStandardConstructors`（1655/1668）、`installTypedArrayIntrinsicExtras`（1824）、`bindMaterializedNativeRecordByAtom`（1956），其余 30 处在文件末尾的测试里。

### `installedConstructor` (`src/exec/standard_globals.zig:1422`)

- **签名**：`fn installedConstructor(constructors: []const ?*core.Object, kind: ConstructorKind) ?*core.Object`。
- **作用**：按 `ConstructorKind` 在安装结果数组里取已建好的构造器对象。
- **实现**：`constructors[@intFromEnum(kind)]`，没装的槽是 null。
- **所有权 / 错误 / 调用**：无：按 `@intFromEnum(kind)` 读 `constructors[]` 数组，返回借用的构造器对象指针或 null，不分配、无 error set。槽为空说明安装顺序排错了（父类还没装），调用方一律 `orelse return error.InvalidBuiltinRegistry`。本文件 11 处调用方、4 个调用函数：`installStandardConstructorWithPrototype` 解析 parent（1497/1499/1506/1509/1512）、`installStandardGlobals`（1742/1754/1757/1758）、`finalizeStandardConstructorGraph`（1810）和 `installTypedArrayIntrinsicExtras`（1817，取不到时是 `orelse return` 而非报错）。

### `constructorPrototypeObject` (`src/exec/standard_globals.zig:1426`)

- **签名**：`fn constructorPrototypeObject(ctor: *core.Object) ?*core.Object`（原先恒被丢弃的 `rt` 形参已删）。
- **作用**：借出构造器自有的 `prototype` 数据属性对象。
- **实现**：`ctor.getOwnDataObjectBorrowed(core.atom.ids.prototype)`，缺失返回 null。
- **所有权 / 错误 / 调用**：返回借用指针，不加引用。

### `materializeBuiltinNamespace` (`src/exec/standard_globals.zig:1431`)

- **签名**：`fn materializeBuiltinNamespace(rt: *core.JSRuntime, global: *core.Object, kind: core.property.AutoInitKind) anyerror!?core.JSValue`。
- **作用**：`rt.materialize_builtin_namespace_cb` 的回调适配器：把 `materializeBuiltinNamespaceAutoInit` 的结果包成 `anyerror!?JSValue`。
- **实现**：`return try materializeBuiltinNamespaceAutoInit(rt, global, kind);` 一行。没有分支：`?JSValue` 的 null 分支永远不产生（`materializeBuiltinNamespaceAutoInit` 要么给值要么给 error），null 只是为了满足 `core` 侧回调签名里「没有可物化的命名空间」这个概念——真走到 null 的话 `Object.materializeBuiltinNamespaceAutoInit`（`src/core/object.zig:8035`）会把它变成 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：只是把 `materializeBuiltinNamespaceAutoInit` 的 `!core.JSValue` 包成回调签名要的 `anyerror!?core.JSValue`（core 不想 name exec 的错误集），自身不分配。**唯一「调用方」不是直接调用**：`installStandardGlobals`（`src/exec/standard_globals.zig:1729`）把它的函数指针写进 `rt.materialize_builtin_namespace_cb`，实际由 `Object.materializeBuiltinNamespaceAutoInit`（`src/core/object.zig:8033`）在 AUTOINIT 命中时调，错误再 `@errorCast` 成 `PropertyReadError` 并成为 JS 异常。

### `registerStandardGlobalsDefault` (`src/exec/standard_globals.zig:1438`)

- **签名**：`pub fn registerStandardGlobalsDefault() void`。
- **作用**：把 exec 的安装器注册成进程级默认，让裸 `JSRuntime` 初始化时能拷回调而不让 core 依赖 exec。
- **实现**：调用 `core.runtime.setDefaultStandardGlobalsInstaller(installStandardGlobals, standardGlobalOwnPropertyCapacity())`。
- **所有权 / 错误 / 调用**：进程全局副作用。之后新建 Runtime 复制这份回调。

### `configureRuntime` (`src/exec/standard_globals.zig:1445`)

- **签名**：`pub fn configureRuntime(rt: *core.JSRuntime) void`。
- **作用**：给已有 Runtime 钉上标准全局安装回调及其容量，保持两者一起变。
- **实现**：调用 `registerStandardGlobalsDefault`，再写 `rt.install_standard_globals_cb` 与 `rt.standard_global_own_property_capacity`。
- **所有权 / 错误 / 调用**：不分配。binding / 测试在已持有 Runtime 时走这一入口。

### `installStandardConstructor` (`src/exec/standard_globals.zig:1454`)

- **签名**：`fn installStandardConstructor( rt: *core.JSRuntime, global: *core.Object, constructors: *[constructor_kind_count]?*core.Object, name: []const u8, kind: ConstructorKind, length: i32, static_methods: []const Method, prototype_methods: []const Method, ) !void`。
- **作用**：安装一个具名标准构造器及其 `.prototype`、静态方法表与原型方法表，原型由 `defineConstructor` 现场新建；`installStandardConstructors` 里绝大多数条目走这个入口。
- **实现**：转发 `installStandardConstructorWithPrototype`，`existing_prototype` 传 null（即由 `defineConstructor` 新建原型）。
- **所有权 / 错误 / 调用**：纯转发（`existing_prototype` 传 null），自身不分配。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 调用方只有 `installStandardConstructors`（`src/exec/standard_globals.zig:1673` 起连续约 40 行，Array/String/Number/… 一行一个构造器），安装顺序就写在那一串调用里。

### `installStandardConstructorWithPrototype` (`src/exec/standard_globals.zig:1467`)

- **签名**：`fn installStandardConstructorWithPrototype( rt: *core.JSRuntime, global: *core.Object, constructors: *[constructor_kind_count]?*core.Object, name: []const u8, kind: ConstructorKind, length: i32, static_methods: []const Method, prototype_methods: []const Method, existing_prototype: ?*core.Object, ) !void`。
- **作用**：构造器安装的总入口：定出 constructor / prototype 各自的父对象，建构造器，登记进 `constructors[]` 数组与 realm 的 class-prototype、native-error 槽，再按 kind 分派到各自的 extras 安装器。直接调它（而不经 `installStandardConstructor`）的只有 `Object` 与 `Function` 两条——它们的原型在 global 建立时就已存在，要通过 `existing_prototype` 复用而非新建。
- **实现**：先取 global 缓存的 Function.prototype。按 kind 选 `constructor_parent`（native Error 子类继承 Error 构造器，具体 TypedArray 继承 `%TypedArray%`，其余是 Function.prototype）与 `prototype_parent`（Object 为 null，Error 子类/DOMException 取 Error.prototype，具体 TypedArray 取 `%TypedArray%.prototype`，其余 Object.prototype）。`defineConstructor` 后写入 `constructors[kind]`；有 class prototype id 就 `realm.setClassPrototype`，Error 家族再 `realm.setNativeErrorPrototype`。没提前装的静态方法在此装。随后按 kind 走各自 extras（缓存 realm 值、盖构造器记录 id、Array 的 `arrayBuiltinMarkerSlot`、species、别名等），最后补 `@@toStringTag`、TypedArray 元素大小、Uint8Array codec 与集合 extras。
- **所有权 / 错误 / 调用**：新建的构造器对象由 `defineConstructor` 挂到 global 上（那边用 `core.runtime.rootValues` 建了一帧 GC 根护住半成品），本函数只把返回的裸指针写进 `constructors[@intFromEnum(kind)]` 这张**栈上的**安装台账——这张表不是 GC 根，靠 global 属性和 realm 槽持有。此外还把原型登记进 realm 的 `class_proto[]`（`setClassPrototype`）和 `native_error_proto[]`（`setNativeErrorPrototype`）。错误来源密集：查不到 `Function.prototype`、父构造器没装、原型取不出来，一律 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 3 个调用方：`installStandardConstructor`（1481）转发，以及 `installStandardConstructors` 里给 Object（1671）和 Function（1672）传预建原型。

### `installStandardConstructors` (`src/exec/standard_globals.zig:1617`)

- **签名**：`fn installStandardConstructors( rt: *core.JSRuntime, global: *core.Object, constructors: *[constructor_kind_count]?*core.Object, ) !void`。
- **作用**：按 QuickJS 基本对象顺序创建 Object.prototype / Function.prototype，再逐个安装全部标准构造器。
- **实现**：先造 null-prototype 的 Object.prototype 与继承它的 Function.prototype，缓存 function proto。然后按 Object、Function、Array、…、Iterator 的固定顺序逐条调 `installStandardConstructor`（Object / Function 两条走 `installStandardConstructorWithPrototype` 并传入预建原型）。末尾遍历 `constructors[]`，任一槽为 null 即 `error.InvalidBuiltinRegistry`（不是 `std.debug.assert`，Release 下也生效）。
- **所有权 / 错误 / 调用**：本函数自己只为预建的 Object.prototype 与 Function.prototype 各建一帧 `core.runtime.rootValues` 根（`live_object_proto` / `live_function_proto`），各构造器值的根在 `defineConstructor` 内部建；`constructors[]` 是调用方栈上的台账，不是 GC 根。失败一律 `error.InvalidBuiltinRegistry` 或分配错误。

### `installStandardGlobals` (`src/exec/standard_globals.zig:1708`)

- **签名**：`pub fn installStandardGlobals(rt: *core.JSRuntime, global: *core.Object) !void`。
- **作用**：把一个 realm 的标准 ECMAScript 全局对象图装齐：构造器、惰性命名空间、全局函数、初始 shape。
- **实现**：先 `configureRuntime` 并挂 `materialize_builtin_namespace_cb`，把 `rt.internal_builtins` 指到 `internal_builtins.table`。用 object root 钉住 constructing 的 global，预留 own-property 容量，然后 `installStandardConstructors` + `finalizeStandardConstructorGraph`。把 global 的 prototype 设成 `Object.prototype`。Math/JSON/Reflect/Atomics 走 AUTOINIT 惰性命名空间；performance/navigator 同样占位。全局函数分两段安装（先 parseInt/parseFloat，再其余），中间把这两个函数别名发布到 Number 构造器上。最后 `initializeInitialShapes`，再 `publishStandardArrayPrototype`。
- **所有权 / 错误 / 调用**：bootstrap 只在 owner 线程跑。构造中的 realm 不在 `context_head` 上，所以 global 必须显式 root。失败返回 `error.InvalidBuiltinRegistry` 或分配错误。调用方：`JSRuntime.installStandardGlobals`、`Intrinsics.init`。

### `installNumberParseAliases` (`src/exec/standard_globals.zig:1752`)

- **签名**：`fn installNumberParseAliases(rt: *core.JSRuntime, global: *core.Object, number: *core.Object) !void`。
- **作用**：把 global 上刚装好的 `parseInt` / `parseFloat` 值发布成 `Number` 的同名静态方法（覆盖 Number 上的 AUTOINIT 占位）。
- **实现**：对两个名字各取一次 `temporaryStringAtom`（defer 释放），再 `publishMethodAlias(rt, number, global, key, key, true)`——target 是 Number，source 是 global。
- **所有权 / 错误 / 调用**：不分配函数：从 `Number` 上取到的 `parseInt`/`parseFloat` 会被 AUTOINIT 物化一次，然后同一个对象发布到 global（`replace_existing_auto_init = true`，覆盖 global 上先装的占位），所以 `Number.parseInt === globalThis.parseInt`。两个名字 atom 在循环内 pin/unpin 配对。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardGlobals`（`src/exec/standard_globals.zig:1755`），夹在 `defineGlobalLazyMethods` 的两段之间。

### `installNumberConstants` (`src/exec/standard_globals.zig:1760`)

- **签名**：`fn installNumberConstants(rt: *core.JSRuntime, number: *core.Object) !void`。
- **作用**：在 Number 构造器上装 8 个不可写、不可枚举、不可配置的数值常量。
- **实现**：用 `{writable=false, enumerable=false, configurable=false}` 的 flags 和一张 8 元素名字数组（MAX_VALUE / MIN_VALUE / NaN / NEGATIVE_INFINITY / POSITIVE_INFINITY / EPSILON / MAX_SAFE_INTEGER / MIN_SAFE_INTEGER），先 `number.reserveOwnPropertyCapacityAssumingPlain(rt, prop_count + 8)` 一次扩容，再逐个 `temporaryStringAtom`（`defer` 归还）+ `defineDataAtomAssumingNew`，取值走 `numberConstantValue(name)`，查不到即 `error.InvalidBuiltinRegistry`。名字表与 `numberConstantValue` 的分支表是两份，必须对齐。
- **所有权 / 错误 / 调用**：只装不可变数字常量，不分配对象；8 个名字 atom 在各自循环轮内 pin/unpin 配对。错误：`error.InvalidBuiltinRegistry`（名字表与取值表脱节）+ reserve/define 的分配失败。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1367`），在 `.number` 分支、装 `.prototype` 之前跑，所以这 8 条是 Number 构造器上最早的属性。

### `numberConstantValue` (`src/exec/standard_globals.zig:1780`)

- **签名**：`fn numberConstantValue(name: []const u8) ?core.JSValue`。
- **作用**：把 Number 常量名映射到它的 `JSValue`。
- **实现**：一串 `std.mem.eql`：NaN、±Infinity、`floatMax` 作 MAX_VALUE、最小非规格化数作 MIN_VALUE、±9007199254740991、EPSILON 2.220446049250313e-16；未知名字返回 null。
- **所有权 / 错误 / 调用**：无：一串 `std.mem.eql` 或链返回立即数 `JSValue`，不分配、无 error set，未命中返回 null。唯一调用方 `installNumberConstants`（`src/exec/standard_globals.zig:1793`），在那里 `orelse return error.InvalidBuiltinRegistry`。

### `finalizeStandardConstructorGraph` (`src/exec/standard_globals.zig:1792`)

- **签名**：`fn finalizeStandardConstructorGraph(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void`。
- **作用**：构造器图收尾：把 `Object.prototype` 标成 immutable prototype，再装 `%TypedArray%` 的 intrinsic extras。
- **实现**：两件事：取出 Object 构造器的原型并 `markImmutablePrototype()`（对标 qjs 给 `Object.prototype` 打上不可改原型位），然后 `installTypedArrayIntrinsicExtras(rt, global, constructors)` 补 `%TypedArray%.prototype` 上那批只能在所有构造器都装完之后才装的东西。取不到 Object 构造器或它的 `.prototype` 即 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：不分配；`constructors` 是调用方栈上的安装台账，只读。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardGlobals`（`src/exec/standard_globals.zig:1741`），紧接在 `installStandardConstructors` 之后——它依赖 `.array_prototype` 这类 realm 缓存槽已经填好。

### `installTypedArrayIntrinsicExtras` (`src/exec/standard_globals.zig:1799`)

- **签名**：`fn installTypedArrayIntrinsicExtras(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void`。
- **作用**：给 `%TypedArray%` 收尾：species、从 `Array.prototype` 借来的 `toString`、intrinsic extra 方法表、`values`→`@@iterator` 别名、原型 accessor。
- **实现**：`%TypedArray%` 没装（`installedConstructor` 返回 null）就**静默 return**，不报错。否则：`installTypedArraySpecies` 装构造器上的 `[Symbol.species]`；取原型并一次 reserve 8 个槽；从 realm 缓存槽 `.array_prototype` 取出 `Array.prototype`（不是对象即 `error.InvalidBuiltinRegistry`），`publishTypedArrayToStringAlias` 把它的 `toString` 复制过来并补 typed-array marker；`defineNativeMethodsAssumingNewWithRealm` 铺 `typed_array_intrinsic_extra_methods`；`publishMethodAlias` 把 `values` 发布成 `[Symbol.iterator]`；最后 `installTypedArrayPrototypeAccessors` 装 buffer/byteLength/byteOffset/length 四个访问器加 `@@toStringTag`。
- **所有权 / 错误 / 调用**：不新建函数对象，只复制已有的（`toString`、`values`）并铺 AUTOINIT 占位；`array_proto` 是从 realm 缓存槽借来的。错误：`error.InvalidBuiltinRegistry`（realm 缓存槽缺 `.array_prototype`）+ 下游各处。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `finalizeStandardConstructorGraph`（`src/exec/standard_globals.zig:1813`）。

### `isNativeErrorSubclassKind` (`src/exec/standard_globals.zig:1816`)

- **签名**：`fn isNativeErrorSubclassKind(kind: ConstructorKind) bool`。
- **作用**：判断该 kind 是否是继承 Error 的 native error 子类（含 AggregateError / SuppressedError，不含 Error 本体与 DOMException）——`installStandardConstructorWithPrototype` 用它决定 `constructor_parent` 取 Error 构造器、`prototype_parent` 取 `Error.prototype`。
- **实现**：白名单 switch，9 个 kind 为 true：`.aggregate_error`、`.suppressed_error` 与 `.eval_error` / `.range_error` / `.reference_error` / `.syntax_error` / `.type_error` / `.uri_error` / `.internal_error`；其余 false。比 `isErrorConstructorKind` 少了 `.error_`。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 两个调用方都在 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1496` 与 1505），分别决定构造器的 `[[Prototype]]` 是不是 `Error` 本身、原型的 `[[Prototype]]` 是不是 `Error.prototype`。与 `isErrorConstructorKind`（1397）的差别是这里**不含** `.error_` 基类。

### `isConcreteTypedArrayKind` (`src/exec/standard_globals.zig:1832`)

- **签名**：`fn isConcreteTypedArrayKind(kind: ConstructorKind) bool`。
- **作用**：判断该 kind 是否是 12 种具体 TypedArray 构造器之一（不含抽象的 `%TypedArray%`），用于把它们的 `constructor_parent` / `prototype_parent` 接到 `%TypedArray%` 上。
- **实现**：白名单 switch，12 个元素类型为 true：`.int8_array`、`.uint8_array`、`.uint8_clamped_array`、`.int16_array`、`.uint16_array`、`.int32_array`、`.uint32_array`、`.float16_array`、`.float32_array`、`.float64_array`、`.bigint64_array`、`.biguint64_array`；`.typed_array`（抽象基类）与其余 kind 落 `else => false`。
- **所有权 / 错误 / 调用**：无：纯 switch/算术查表，不碰 runtime、不分配、无 error set。 两个调用方同在 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1498` 与 1508）：12 个具体 TypedArray 的构造器父类是 `%TypedArray%`、原型父类是 `%TypedArray%.prototype`。抽象的 `.typed_array` 自身不在表内。

### `installMathConstants` (`src/exec/standard_globals.zig:1851`)

- **签名**：`fn installMathConstants(rt: *core.JSRuntime, math: *core.Object) !void`。
- **作用**：在 Math 命名空间上装 E / LN10 / LN2 / LOG2E / LOG10E / PI / SQRT1_2 / SQRT2 八个只读常量。
- **实现**：先拿一份 `{writable=false, enumerable=false, configurable=false}` 的 flags，然后八条平铺的 `defineDataAtom(rt, math, core.atom.ids.<NAME>, core.JSValue.float64(math_builtin.<NAME>), flags)`——没有循环、没有分支、不预留容量（容量由 `math_namespace_extra_property_count` 在建命名空间时一次算进去）。常量值来自 `math_builtin`，键是预定义 atom id。
- **所有权 / 错误 / 调用**：8 条 `defineDataAtom`，键全是 `core.atom.ids.*` 预定义常量（不 intern、不 pin），值是编译期 f64 立即数，不分配对象。与多数 install 函数不同，**它跑在 AUTOINIT 物化路径上**：唯一调用方 `materializeBuiltinNamespaceAutoInit`（`src/exec/standard_globals.zig:1096`）在首次读 `globalThis.Math` 时触发，分配失败会成为一次属性读失败并抛 JS 异常，而不是 bootstrap 失败。注意这里用的是查重版 `defineDataAtom` 而非 `AssumingNew`。

### `bindMathNativeRecords` (`src/exec/standard_globals.zig:1863`)

- **签名**：`fn bindMathNativeRecords(rt: *core.JSRuntime, math: *core.Object) !void`。
- **作用**：给刚物化出来的 `Math` 命名空间对象上的每个方法盖上 `.math` 域的 native 记录 id，让它们脱离按名字分发的兜底路径。
- **实现**：遍历 `math_builtin.internal_entries`（`Math` 的记录表本身就是方法清单），逐条 `bindNativeRecordByName(rt, math, entry.name, .math, entry.id)`；因为表与安装用的 `math_methods` 同源，不做存在性兜底。
- **所有权 / 错误 / 调用**：遍历 `math_builtin.internal_entries` 给每个方法槽补 `(.math, id)` 记录，不分配对象（AUTOINIT 槽命中时连 `getProperty` 都不做）。同属 AUTOINIT 物化路径：唯一调用方 `materializeBuiltinNamespaceAutoInit`（`src/exec/standard_globals.zig:1095`），错误成为 `globalThis.Math` 读失败。

### `bindAtomicsNativeRecords` (`src/exec/standard_globals.zig:1869`)

- **签名**：`fn bindAtomicsNativeRecords(rt: *core.JSRuntime, atomics: *core.Object) !void`。
- **作用**：`Atomics` 命名空间的同形动作：把 `.atomics` 域的记录 id 绑到刚建好的方法上。
- **实现**：遍历 `atomics_builtin.internal_entries`，逐条 `bindNativeRecordByName(rt, atomics, entry.name, .atomics, entry.id)`。
- **所有权 / 错误 / 调用**：与 `bindMathNativeRecords` 同形，域换成 `.atomics`、表换成 `atomics_builtin.internal_entries`。唯一调用方 `materializeBuiltinNamespaceAutoInit`（`src/exec/standard_globals.zig:1108`），跑在首次读 `globalThis.Atomics` 时；注意 Atomics 分支是先 `installNamespaceToStringTag` 再绑记录，与 Math/Reflect 的顺序相反（对结果无影响）。

### `bindReflectNativeRecords` (`src/exec/standard_globals.zig:1875`)

- **签名**：`fn bindReflectNativeRecords(rt: *core.JSRuntime, reflect: *core.Object) !void`。
- **作用**：`Reflect` 命名空间的同形动作，但驱动方向相反：从安装用的方法表出发去反查记录 id。
- **实现**：遍历 `reflect_methods` 这张 `Method` 表，对每个名字调 `reflect_builtin.methodId(method.name)`；查不到就 `continue` 跳过（允许方法表里存在还没有记录的条目），命中才 `bindNativeRecordByName(rt, reflect, method.name, .reflect, id)`。
- **所有权 / 错误 / 调用**：遍历的是本文件的 `reflect_methods` 表而不是 internal_entries，`reflect_builtin.methodId(name)` 查不到就 `continue` **静默跳过**（其余两个 bind 函数没有这条容错）。不分配。唯一调用方 `materializeBuiltinNamespaceAutoInit`（`src/exec/standard_globals.zig:1103`），首次读 `globalThis.Reflect` 时触发。

### `defineCollectionPrototypeMethodsAssumingNew` (`src/exec/standard_globals.zig:1882`)

- **签名**：`fn defineCollectionPrototypeMethodsAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object, name: []const u8) !void`。
- **作用**：按集合名安装原型方法表，Map/Set 中途插入 `size` accessor 以保持属性顺序。
- **实现**：按集合名分三路。`"Map"`：先铺 `map_prototype[0..7]`，插一个 `size` 访问器（`defineCollectionSizeAccessorAssumingNew`，owner class `map`），再铺 `map_prototype[7..]`——切分点就是为了让 `size` 落在 QuickJS 的属性顺序位上。`"Set"` 同构，切分点是 4、owner class `set`。其余（WeakMap / WeakSet）走 `collectionPrototypeMethods(name)` 一次铺完，查不到名字即 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：方法全是 AUTOINIT 占位（静态 `Method` 表地址），只有 `size` 那条会真建一个 getter 函数对象。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installCollectionExtras`（`src/exec/standard_globals.zig:3117`），且只在 Map/Set 分支进（WeakMap/WeakSet 的原型方法是走 `defineConstructor` 的通用路径装的，这里的 else 臂今天走不到）。

### `defineCollectionSizeAccessorAssumingNew` (`src/exec/standard_globals.zig:1896`)

- **签名**：`fn defineCollectionSizeAccessorAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object, owner_class: core.ClassId) !void`。
- **作用**：在集合原型上装 `size` 惰性 getter，并带上 collection owner class 元数据。
- **实现**：用 `.collection` domain 的 `size_getter` id 加 `.collection_owner` tag 调 `defineLazyNativeGetterAtomWithRealmAndMetadata`，flags 为不可写、不可枚举、可配置。
- **所有权 / 错误 / 调用**：会真建一个 `get size` 函数对象，并同时盖上 `(.collection, size_getter)` 记录 id 和 `collection_owner = owner_class` 标记——后者是运行时区分 Map 与 Set 的 `size` 的唯一依据，metadata 两项缺一，热路径就会拿错 receiver 类。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 两个调用方都在 `defineCollectionPrototypeMethodsAssumingNew`（`src/exec/standard_globals.zig:1902` Map、1906 Set）。

### `setDateConstructorNativeRecord` (`src/exec/standard_globals.zig:1913`)

- **签名**：`fn setDateConstructorNativeRecord(rt: *core.JSRuntime, ctor: *core.Object) void`。
- **作用**：给 Date 构造器对象盖上 `.date` domain 的 construct 记录。
- **实现**：一句 `setNativeBuiltinIdAndRecord(rt, nativeBuiltinId(.date, ConstructorMethod.construct))`。
- **所有权 / 错误 / 调用**：无：单行 `setNativeBuiltinIdAndRecord`，在已有构造器对象上写 id 并解析 `NativeEntry`，不分配、返回 void、**无 error set**（是本族里少数不返回 error 的）。唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1597`）的 `.date` 分支。

### `bindNativeRecordByName` (`src/exec/standard_globals.zig:1917`)

- **签名**：`fn bindNativeRecordByName( rt: *core.JSRuntime, object: *core.Object, name: []const u8, domain: core.function.NativeBuiltinDomain, id: u32, ) !void`。
- **作用**：按属性名给一个已安装的方法绑 native 记录：属性若还是 AUTOINIT 占位就只做一致性确认（不物化），已物化成函数对象才真去盖 id。
- **实现**：`temporaryStringAtom` 取键（`defer` 归还）、`nativeBuiltinId(domain, id)` 编码。先试 `bindAutoInitNativeRecordByAtom`：若该键还是未物化的 AUTOINIT 槽且槽里的 `native_builtin_id` 已经等于要绑的值，直接返回——**不物化函数对象**，这是命名空间物化路径上的主要省事点。否则退到 `bindMaterializedNativeRecordByAtom`，那条会 `getProperty` 触发物化再盖 id。
- **所有权 / 错误 / 调用**：名字 atom 的 pin 在函数内 `defer` 配对；快路径不分配，慢路径会物化出一个函数对象并留在属性表里。跑在 AUTOINIT 物化路径上（三个调用方 `bindMathNativeRecords`（`src/exec/standard_globals.zig:1882`）、`bindAtomicsNativeRecords`（1888）、`bindReflectNativeRecords`（1895）都只被 `materializeBuiltinNamespaceAutoInit` 调），错误经 `PropertyReadError` 成为 JS 异常。

### `bindMaterializedNativeRecordByAtom` (`src/exec/standard_globals.zig:1931`)

- **签名**：`fn bindMaterializedNativeRecordByAtom( rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, native_id: i32, ) !void`。
- **作用**：上一条的「已物化」分支：读出属性值，是对象就给它盖 `native_builtin_id` 并解析出对应 `NativeEntry`。
- **实现**：`object.getProperty(atom_id)` 取值——若该属性仍是 AUTOINIT，这一步会把它真正物化；取到的不是对象就静默返回（不报错，容忍表里列了未安装的名字），是对象则 `expectObjectAssumeBootstrap` 解包后 `setNativeBuiltinIdAndRecord(rt, native_id)`。
- **所有权 / 错误 / 调用**：`getProperty` 会物化 AUTOINIT 槽、真建出函数对象（所有权归属性表）；取到的不是对象就**静默 return**，不报错。错误只有 `getProperty` 的 `PropertyReadError` 与分配失败。唯一调用方是上面的 `bindNativeRecordByName`（`src/exec/standard_globals.zig:1945`）的慢路径，同样跑在命名空间 AUTOINIT 物化里。

### `bindAutoInitNativeRecordByAtom` (`src/exec/standard_globals.zig:1943`)

- **签名**：`fn bindAutoInitNativeRecordByAtom(_: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, native_id: i32) bool`。
- **作用**：检查某属性是否仍是 AUTOINIT 占位且描述符里已带同一 native id——是则不需要再物化绑定。
- **实现**：对象有 exotic methods 返回 false；`findProperty` 找不到返回 false；属性 kind 非 `.auto_init` 返回 false；否则比较 `core.property.autoInit(...).native_builtin_id == native_id`。
- **所有权 / 错误 / 调用**：第一个参数（rt）未用。不分配。

### `installTypedArrayElementSize` (`src/exec/standard_globals.zig:1958`)

- **签名**：`fn installTypedArrayElementSize(rt: *core.JSRuntime, ctor: *core.Object, size: i32, kind: u8) !void`。
- **作用**：给一个具体 TypedArray 构造器钉死元素宽度：写对象内的 element-size / kind 槽，并保证构造器与原型上都有 `BYTES_PER_ELEMENT` 常量。
- **实现**：先写构造器的 `typedArrayElementSizeSlot` / `typedArrayKindSlot`；构造器上还没有 `BYTES_PER_ELEMENT` 时补调 `installTypedArrayConstructorElementSize`；再在原型上预留一槽并装同名只读常量。缺原型返回 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：写的是构造器对象上的两个定长内嵌槽（`typedArrayElementSizeSlot` / `typedArrayKindSlot`，借用可变指针，不分配），再给构造器与原型各补一条 `BYTES_PER_ELEMENT` 数据属性。构造器那条带 `hasOwnProperty` 幂等保护（`defineConstructor` 可能已经装过），原型那条没有——重复调用会踩 `AssumingNew` 的前置条件。错误：取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1628`），条件是 `typed_array_names.element(name)` 命中。

### `installTypedArrayConstructorElementSize` (`src/exec/standard_globals.zig:1970`)

- **签名**：`fn installTypedArrayConstructorElementSize(rt: *core.JSRuntime, ctor: *core.Object, size: i32) !void`。
- **作用**：只在 TypedArray 构造器（而非原型）上装 `BYTES_PER_ELEMENT` 只读常量；`defineConstructor` 建每个具体 TypedArray 构造器时直接调它，`installTypedArrayElementSize` 在构造器还缺这条时也会补调。
- **实现**：取预定义 atom `BYTES_PER_ELEMENT`，`reserveOwnPropertyCapacityAssumingPlain(prop_count + 1)` 预留一槽后 `defineDataAtomAssumingNew` 写入 `core.JSValue.int32(size)`，三个 flag 全 false（不可写 / 不可枚举 / 不可配置）。
- **所有权 / 错误 / 调用**：一次 reserve + 一条 `defineDataAtomAssumingNew`，不分配对象、无所有权动作；键是预定义 atom。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 两个调用方：`defineConstructor`（`src/exec/standard_globals.zig:1373`，构造器刚建好时装）与 `installTypedArrayElementSize`（1980，`hasOwnProperty` 兜底）——两条路径互斥，靠后者（`installTypedArrayElementSize` 1979 行）的 `hasOwnProperty` 检查保证只装一次。

### `installUint8ArrayConstructorCodecExtras` (`src/exec/standard_globals.zig:1976`)

- **签名**：`fn installUint8ArrayConstructorCodecExtras(rt: *core.JSRuntime, ctor: *core.Object) !void`。
- **作用**：在 `Uint8Array` 构造器上装两个 base64 / hex 解码静态方法 `fromBase64`、`fromHex`。
- **实现**：单行 `defineNativeMethodsAssumingNew(rt, ctor, &uint8_array_constructor_codec_methods)`，表里两条 length 都是 1，装成 AUTOINIT 占位。
- **所有权 / 错误 / 调用**：单行转发 `defineNativeMethodsAssumingNew`，铺 `uint8_array_constructor_codec_methods`（`fromBase64` / `fromHex` 等）的 AUTOINIT 占位，不建函数对象、不预留容量（容量已由 `constructorExtraPropertyCount(.uint8_array) == 3` 算进构造器）。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 两个调用方：`defineConstructor`（`src/exec/standard_globals.zig:1374`）与 `installUint8ArrayCodecExtras`（2000），后者用 `hasOwnProperty(fromBase64)` 避免重装。

### `installUint8ArrayCodecExtras` (`src/exec/standard_globals.zig:1980`)

- **签名**：`fn installUint8ArrayCodecExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装齐 Uint8Array 的 base64 / hex 编解码提案：构造器侧 `fromBase64` / `fromHex`，原型侧 `toBase64` / `toHex` / `setFromBase64` / `setFromHex`。
- **实现**：先用 `core.atom.ids.fromBase64` 做幂等判断——`defineConstructor` 已经在建 `Uint8Array` 时装过构造器侧方法，只有缺失时才补调 `installUint8ArrayConstructorCodecExtras`；随后 `constructorPrototypeObject` 取 `.prototype`（缺则 `error.InvalidBuiltinRegistry`），用 `defineNativeMethodsAssumingNewWithRealm` 把 `uint8_array_prototype_codec_methods`（`toBase64`/`toHex` length 0、`setFromBase64`/`setFromHex` length 1）装成 AUTOINIT。
- **所有权 / 错误 / 调用**：构造器侧带 `hasOwnProperty(core.atom.ids.fromBase64)` 幂等保护，原型侧无保护直接 `defineNativeMethodsAssumingNewWithRealm` 铺 `uint8_array_prototype_codec_methods`。不建函数对象。错误：取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1630`），`kind == .uint8_array` 时。

### `installTypedArrayPrototypeAccessors` (`src/exec/standard_globals.zig:1990`)

- **签名**：`fn installTypedArrayPrototypeAccessors(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object) !void`。
- **作用**：在 `%TypedArray%.prototype` 上装 4 个只读访问器 `buffer` / `byteLength` / `byteOffset` / `length`，外加 `@@toStringTag` 的 getter（TypedArray 的 tag 是动态算出来的，所以是访问器而不是字符串常量）。
- **实现**：本地 4 元数组给出 (property_name, getter_name) 对，一次 `reserveOwnPropertyCapacityAssumingPlain(prop_count + 4 + 1)` 预留全部槽位；每条用 `buffer_ops.typedArrayAccessorMethodId(property_name)` 查 `.buffer` 域的方法 id（查不到就传 0，即不盖记录），atom 走 `core.atom.predefinedId(..., .string)`（缺失报 `error.InvalidBuiltinRegistry`），再 `defineLazyNativeGetterAtomWithRealm`，flags 统一是不可写 / 不可枚举 / 可配置；循环后用同样方式装 `"[Symbol.toStringTag]"` 的 getter。
- **所有权 / 错误 / 调用**：会真建 5 个 getter 函数对象（buffer / byteLength / byteOffset / length 加 `@@toStringTag`），每个都由 `defineLazyNativeGetterAtomWithRealm` 当场写进访问器属性，无中间根。`buffer_ops.typedArrayAccessorMethodId` 查不到时 native id 填 0（**静默降级**成无记录的 getter，热路径会退回名字级联），而 atom 查不到才 `error.InvalidBuiltinRegistry`。栈上的 `accessors` 数组是 comptime 常量表，不需要释放。错误集由 Zig 推断（只有 `error.OutOfMemory` 与本文件自己 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即 `rollbackIntrinsicBootstrap` 并让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installTypedArrayIntrinsicExtras`（`src/exec/standard_globals.zig:1830`）。

### `keep` (`src/exec/standard_globals.zig:2048`)

- **签名**：`fn keep(id: u32) bool`。
- **作用**：`object_prototype` 安装表的过滤器：只保留 `object_builtin.prototypeMethodOrdinal(id)` 非空的条目。
- **实现**：交给 `methodsFromInternalEntriesWhere`，把 Object 的 `internal_entries` 拆成原型方法表（静态方法走另一张 `object_static`）。
- **所有权 / 错误 / 调用**：comptime。匿名 struct 里的谓词。

### `methodsFromInternalEntries` (`src/exec/standard_globals.zig:2557`)

- **签名**：`fn methodsFromInternalEntries( comptime entries: []const core.host_function.InternalEntry, comptime domain: core.function.NativeBuiltinDomain, ) [entries.len]Method`。
- **作用**：comptime 把一张 `internal_entries` 投影成安装用的 `Method` 表（Math / JSON 的命名空间方法表就是这么来的）。
- **实现**：逐条取 `name`/`length`，id 编码成 `nativeBuiltinId(domain, entry.id)`。
- **所有权 / 错误 / 调用**：无：纯 comptime，不分配、无 error set。 返回的数组是 comptime 值，被赋给 `const` 后成为静态表，AUTOINIT 槽存的就是它元素的地址——所以它必须是 `const` 全局而不能是函数内局部。两个调用方：`math_methods`（`src/exec/standard_globals.zig:2570`）与 `json_methods`（2572）。

### `methodsFromInternalEntriesWhere` (`src/exec/standard_globals.zig:2575`)

- **签名**：`fn methodsFromInternalEntriesWhere( comptime entries: []const core.host_function.InternalEntry, comptime domain: core.function.NativeBuiltinDomain, comptime keep: fn (id: u32) bool, ) [countInternalEntriesWhere(entries, keep)]Method`。
- **作用**：只取 id 满足 `keep` 的条目投影成 `Method` 表并保持声明顺序，用来把一张 `internal_entries`（如 Object 的）拆成静态表与原型表。
- **实现**：数组长度由 `countInternalEntriesWhere` 在 comptime 求出；跳过 `keep` 为假的条目，其余与 `methodsFromInternalEntries` 相同。
- **所有权 / 错误 / 调用**：无：纯 comptime，不分配、无 error set。 返回类型自身要先调 `countInternalEntriesWhere` 算长度，所以 `keep` 谓词在一次调用里被跑两遍，必须是纯函数。唯一调用方 `object_prototype`（`src/exec/standard_globals.zig:2064`），把 Object 的单张 internal entry 表按 id 切成静态表与原型表两份。

### `countInternalEntriesWhere` (`src/exec/standard_globals.zig:2594`)

- **签名**：`fn countInternalEntriesWhere( comptime entries: []const core.host_function.InternalEntry, comptime keep: fn (id: u32) bool, ) usize`。
- **作用**：comptime 数出满足 `keep` 的条目数，给 `methodsFromInternalEntriesWhere` 定数组长度。
- **实现**：线性遍历计数。
- **所有权 / 错误 / 调用**：无：纯 comptime，不分配、无 error set。 只为给上面那个函数的返回类型定长度而存在，两个调用点都在 `methodsFromInternalEntriesWhere` 内（`src/exec/standard_globals.zig:2596` 返回类型、2597 局部数组类型）。

### `installSymbolExtras` (`src/exec/standard_globals.zig:2645`)

- **签名**：`fn installSymbolExtras(rt: *core.JSRuntime, global: *core.Object, symbol_ctor: *core.Object) !void`。
- **作用**：在 `Symbol.prototype` 上补三条方法表装不了的属性：`description` getter、`[Symbol.toPrimitive]` 与 `[Symbol.toStringTag]`。
- **实现**：取 `.prototype`（缺则 `error.InvalidBuiltinRegistry`）并一次预留 3 槽；`description` 用 `defineLazyNativeGetterAtomWithRealm` 装成 `.primitive` 域 `primitive_symbol_description_get_id` 的只读访问器（不可写 / 不可枚举 / 可配置）；`[Symbol.toPrimitive]` 用 `symbol_to_primitive_auto_init` 描述符装 AUTOINIT，flags 为 (false, false, true)；`[Symbol.toStringTag]` 走 `defineStringConstantAtomAssumingNewWithRealm`，常量串 "Symbol"。
- **所有权 / 错误 / 调用**：三条属性里只有 `description` 会真建一个 getter 函数对象；`[Symbol.toPrimitive]` 写的是静态描述符 `symbol_to_primitive_auto_init` 的借用指针，`@@toStringTag` 是静态常量串的 AUTOINIT。reserve 的 3 与实际装的 3 条对齐。错误：取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1555`）的 `.symbol` 分支。

### `installWellKnownSymbolProperties` (`src/exec/standard_globals.zig:2658`)

- **签名**：`fn installWellKnownSymbolProperties(rt: *core.JSRuntime, symbol_ctor: *core.Object) !void`。
- **作用**：把 15 个 well-known symbol 作为不可写 / 不可枚举 / 不可配置的数据属性挂到 `Symbol` 构造器上（`Symbol.iterator`、`Symbol.species`…）。
- **实现**：先 `reserveOwnPropertyCapacityAssumingPlain(prop_count + 15)`，再按固定顺序 15 次 `defineWellKnownSymbol`：`toPrimitive`、`iterator`、`match`、`matchAll`、`replace`、`search`、`split`、`toStringTag`、`isConcatSpreadable`、`hasInstance`、`species`、`unscopables`、`asyncIterator`、`asyncDispose`、`dispose`。这个 15 与 `constructorExtraPropertyCount(.symbol)` 的 15 必须一致。
- **所有权 / 错误 / 调用**：只是把 15 个 well-known symbol 值挂上构造器，不建函数对象；symbol 值由 `defineWellKnownSymbol` 里的 `rt.symbolValue` 从 runtime 的预定义 symbol 表取（借用，不新建）。reserve 的 15 与调用条数、与 `constructorExtraPropertyCount(.symbol) == 15` 三处必须同时改。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1370`）的 `.symbol` 分支，在装 `.prototype` 之前。

### `defineWellKnownSymbol` (`src/exec/standard_globals.zig:2677`)

- **签名**：`fn defineWellKnownSymbol(rt: *core.JSRuntime, symbol_ctor: *core.Object, name: []const u8, symbol_name: []const u8) !void`。
- **作用**：装一条 `Symbol.xxx` 数据属性，值是运行时里那个唯一的预定义 symbol 值。
- **实现**：`core.atom.predefinedId(symbol_name, .symbol)` 查预定义 symbol atom（形如 `"Symbol.iterator"`，查不到即 `error.InvalidBuiltinRegistry`），`rt.symbolValue(atom)` 取出对应的 symbol 值，再 `defineDataAssumingNew` 以三 flag 全 false 写到构造器上——属性名是不带前缀的短名（`"iterator"`），键与值因此是两套不同的串。
- **所有权 / 错误 / 调用**：`rt.symbolValue(symbol_atom)` 取的是 runtime 预定义 symbol 的值（不新建、不 retain），随后 `defineDataAssumingNew` 以 `{false,false,false}` 装成不可改属性（属性名 atom 由 `defineDataAssumingNew` 内部 pin/unpin）。错误：`symbol_name` 不是预定义 symbol 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 15 个调用方全在 `installWellKnownSymbolProperties`（`src/exec/standard_globals.zig:2677-2691`）。

### `installArrayPrototypeSymbols` (`src/exec/standard_globals.zig:2683`)

- **签名**：`fn installArrayPrototypeSymbols(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装 `Array[Symbol.species]` getter、把 `Array.prototype.values` 再发布成 `[Symbol.iterator]`、并给 `Array.prototype` 装 `[Symbol.unscopables]`。
- **实现**：构造器预留 1 槽、原型预留 2 槽。species getter 走 `defineLazyNativeGetterAtomWithRealmAndMetadata`，id 是 `.host` 域的 `HostGlobalMethod.species_getter`，并额外打 `.array_builtin = .species_getter` 标记（这样数组内建的快路径能认出它没被改写），realm 传 null 由 ctor 自身推。`publishMethodAlias(proto, proto, values, Symbol.iterator, false)` 读出 `values` 的函数对象再以同一个值定义 `@@iterator`（`replace_existing_auto_init = false`，即别名键必须是新的）。最后 `[Symbol.unscopables]` 用 `array_unscopables_auto_init` 装成 AUTOINIT，flags 不可写 / 不可枚举 / 可配置。
- **所有权 / 错误 / 调用**：会建一个 `get [Symbol.species]` 函数对象（同时盖 `(.host, species_getter)` id 与 `array_builtin = .species_getter` 标记，两者缺一热路径认不出）；`[Symbol.iterator]` 只是把已物化的 `values` 函数对象再发布一次（同一对象）；`[Symbol.unscopables]` 写静态描述符 `array_unscopables_auto_init` 的借用指针。构造器与原型各 reserve 一次。错误：取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1567`）的 `.array` 分支。

### `bufferAccessorNativeId` (`src/exec/standard_globals.zig:2723`)

- **签名**：`fn bufferAccessorNativeId(id: u32) i32`。
- **作用**：把 buffer domain 的 accessor 方法 id 编码成 native-builtin id，供三张 `BufferCtorAccessor` 表在 comptime 烘焙。
- **实现**：`core.function.nativeBuiltinId(.buffer, id)`。
- **所有权 / 错误 / 调用**：无：纯 comptime，不分配、无 error set。 只是 `nativeBuiltinId(.buffer, id)` 的一层命名包装，为的是让下面三张 `BufferCtorAccessor` 静态表能在 comptime 把 id 烘死。8 个调用点都在 `array_buffer_ctor_accessors`（`src/exec/standard_globals.zig:2745-2749`）与 `shared_array_buffer_ctor_accessors`（2753-2755）的初始化表达式里，`data_view_accessors`（2759-2761）再 3 处。

### `installArrayBufferExtras` (`src/exec/standard_globals.zig:2747`)

- **签名**：`inline fn installArrayBufferExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装 `ArrayBuffer` 的非方法表部分：构造器上的 `[Symbol.species]`，原型上的 5 个只读访问器、`buffer_prototype` 方法表与 `@@toStringTag`。
- **实现**：转发 `installBufferConstructorExtras`：`array_buffer_ctor_accessors` + `buffer_prototype` + tag "ArrayBuffer"，`predefined_atoms = false`、`install_species = true`。
- **所有权 / 错误 / 调用**：`inline fn`，自身无代码，全部所有权与错误行为在 `installBufferConstructorExtras`（`src/exec/standard_globals.zig:2810`）：它按 accessor 表建若干 getter 函数对象、铺原型方法 AUTOINIT、写 `@@toStringTag` 常量。这里传的参数是 ArrayBuffer：`predefined_atoms = false`、`install_species = true`。注意 `false` 并不代表这些名字缺预定义 atom——`byteLength` / `maxByteLength` / `resizable` / `detached` / `immutable` 全在 `predefined_atoms` 表里（`src/core/atom.zig:384`、`852-855`、`892`），所以 `temporaryStringAtom` 走的也是预定义命中分支，一次 intern 都不会发生；两个臂的真实差别只在缺 atom 时的行为：`true` 臂 `predefinedId` 落空即 `error.InvalidBuiltinRegistry`，`false` 臂会 intern 一个新 atom 并 `defer` 解钉。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1606`）。

### `installSharedArrayBufferExtras` (`src/exec/standard_globals.zig:2760`)

- **签名**：`inline fn installSharedArrayBufferExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：`SharedArrayBuffer` 的同形安装：`[Symbol.species]` + 原型上 3 个访问器（`byteLength` / `maxByteLength` / `growable`）+ `shared_buffer_prototype` 方法表 + tag。
- **实现**：转发 `installBufferConstructorExtras`：`shared_array_buffer_ctor_accessors` + `shared_buffer_prototype` + tag "SharedArrayBuffer"，`predefined_atoms = true`、`install_species = true`。
- **所有权 / 错误 / 调用**：`inline fn`，自身无代码，全部所有权与错误行为在 `installBufferConstructorExtras`（`src/exec/standard_globals.zig:2810`）：它按 accessor 表建若干 getter 函数对象、铺原型方法 AUTOINIT、写 `@@toStringTag` 常量。这里传的参数是 SharedArrayBuffer：`predefined_atoms = true`、`install_species = true`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1610`）。

### `installDataViewExtras` (`src/exec/standard_globals.zig:2773`)

- **签名**：`inline fn installDataViewExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：`DataView` 的同形安装，区别是没有 `[Symbol.species]`：原型上 3 个访问器（`buffer` / `byteLength` / `byteOffset`）+ `data_view_prototype` 方法表 + tag。
- **实现**：转发 `installBufferConstructorExtras`：`data_view_accessors` + `data_view_prototype` + tag "DataView"，`predefined_atoms = true`、`install_species = false`。
- **所有权 / 错误 / 调用**：`inline fn`，自身无代码，全部所有权与错误行为在 `installBufferConstructorExtras`（`src/exec/standard_globals.zig:2810`）：它按 accessor 表建若干 getter 函数对象、铺原型方法 AUTOINIT、写 `@@toStringTag` 常量。这里传的参数是 DataView：`predefined_atoms = true`、`install_species = false`（DataView 没有 `[Symbol.species]`）。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1612`）。

### `installBufferConstructorExtras` (`src/exec/standard_globals.zig:2793`)

- **签名**：`noinline fn installBufferConstructorExtras( rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object, accessors: []const BufferCtorAccessor, methods: []const Method, tag: []const u8, predefined_atoms: bool, install_species: bool, ) !void`。
- **作用**：ArrayBuffer / SharedArrayBuffer / DataView 共用 extras：可选 species、原型 accessor 循环、方法表、`Symbol.toStringTag`。
- **实现**：`install_species` 则 ctor 预留 1 槽，装 `Symbol.species` lazy getter（host `species_getter`）。原型预留 `accessors.len+1`。`predefined_atoms` 用 `predefinedId`，否则 `temporaryStringAtom` + defer free。然后 `defineNativeMethodsAssumingNewWithRealm` 与 toStringTag。outlined leftover：把 DataView extras 收进 buffer extras 走法，species 与 baked accessor id 作运行时标志。不折 TypedArray 原型 accessor。
- **所有权 / 错误 / 调用**：`InvalidBuiltinRegistry` 来自缺原型或缺 predefined atom。`installArrayBufferExtras` / `installSharedArrayBufferExtras` / `installDataViewExtras` 是 inline 包装。

### `defineDatePrototypeMethodsAssumingNew` (`src/exec/standard_globals.zig:2826`)

- **签名**：`fn defineDatePrototypeMethodsAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object) !void`。
- **作用**：把 `date_prototype` 方法表装到 `Date.prototype`（AUTOINIT 形式），并在走到 `toUTCString` 那一条时顺带发布 AnnexB 别名 `toGMTString`。
- **实现**：把 `method_flags` 翻成 packed `core.property.Flags`，`reserveOwnPropertyCapacityAssumingPlain(prop_count + date_prototype.len + 1)`（多出的 1 留给别名）；`bootstrapPropertyRealm(proto, global)` 只解析一次 realm，然后循环：`temporaryStringAtom` 取键（defer 释放）、`defineAutoInitPropertyFromDescriptorWithResolvedRealm` 写 AUTOINIT；名字等于 `"toUTCString"` 时立刻 `installNativeMethodAlias(proto, "toUTCString", "toGMTString")`——这一步会读一次刚写的属性，因此 `toUTCString` 是 `date_prototype` 里唯一被提前物化的方法。
- **所有权 / 错误 / 调用**：与通用的 `defineNativeMethodsAssumingNewWithRealm` 同形（atom pin 轮内配对、AUTOINIT 槽存 `date_prototype` 元素静态地址），区别是 reserve 多留 1 个槽、并在装完 `toUTCString` 的那一轮顺手 `installNativeMethodAlias` 发布 `toGMTString` 别名——别名会 `getProperty` 触发 `toUTCString` 物化，因此这条是 Date 原型上唯一一个提前建出函数对象的方法。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1342`）的 `kind == .date` 分支。

### `installOnePrototypeAutoInit` (`src/exec/standard_globals.zig:2843`)

- **签名**：`noinline fn installOnePrototypeAutoInit( rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object, atom_id: core.atom.Atom, flags: core.property.Flags, info: *const core.property.AutoInit, ) !void`。
- **作用**：在构造器原型上装一条 AUTOINIT 属性（Date `[Symbol.toPrimitive]` / Function `[Symbol.hasInstance]` 的共用走法）。
- **实现**：取原型，缺则 `InvalidBuiltinRegistry`。`reserveOwnPropertyCapacityAssumingPlain(+1)`，再 `defineAutoInitPropertyFromDescriptor`。outlined leftover：comptime 身份只是 atom/flags/auto-init 指针，运行时传入。
- **所有权 / 错误 / 调用**：`installDatePrototypeAliases` / `installFunctionPrototypeExtras` 是 inline 包装。

### `installDatePrototypeAliases` (`src/exec/standard_globals.zig:2856`)

- **签名**：`inline fn installDatePrototypeAliases(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：在 `Date.prototype` 上装 `[Symbol.toPrimitive]`；函数名里的 “Aliases” 是历史遗留，`toGMTString` 别名其实在 `defineDatePrototypeMethodsAssumingNew` 里装。
- **实现**：转发 `installOnePrototypeAutoInit`：在 Date.prototype 上装 `[Symbol.toPrimitive]` 的 AUTOINIT（flags 不可写、不可枚举、可配置）。
- **所有权 / 错误 / 调用**：`inline fn`，只把参数摆好转给 `installOnePrototypeAutoInit`（`src/exec/standard_globals.zig:2860`）。装的是 `Date.prototype[Symbol.toPrimitive]`（静态描述符 `date_to_primitive_auto_init`，flags `{false,false,true}`），不建函数对象（AUTOINIT 槽存静态描述符的借用指针），取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1598`）。

### `installFunctionPrototypeExtras` (`src/exec/standard_globals.zig:2867`)

- **签名**：`inline fn installFunctionPrototypeExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：在 `Function.prototype` 上装 `[Symbol.hasInstance]`，即 `instanceof` 的默认实现入口。
- **实现**：转发 `installOnePrototypeAutoInit`：在 Function.prototype 上装 `[Symbol.hasInstance]` 的 AUTOINIT（三个 flag 全 false）。缺预定义 atom 时 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：`inline fn`，只把参数摆好转给 `installOnePrototypeAutoInit`（`src/exec/standard_globals.zig:2860`）。装的是 `Function.prototype[Symbol.hasInstance]`（静态描述符 `function_has_instance_auto_init`，flags `{false,false,false}`；atom 取不到即 `error.InvalidBuiltinRegistry`），不建函数对象（AUTOINIT 槽存静态描述符的借用指针），取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1601`）。

### `installErrorPrototypeExtras` (`src/exec/standard_globals.zig:2878`)

- **签名**：`fn installErrorPrototypeExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：在 `Error.prototype` 上装 `stack` 的 getter / setter 访问器对（zjs 的 stack 是惰性格式化的，所以不是数据属性）。
- **实现**：取 `.prototype`（缺则 `error.InvalidBuiltinRegistry`）并预留 1 槽；一次 `defineLazyNativeAccessorPairAtom`：键 `core.atom.ids.stack`、getter 名 `"get stack"` 对应 `.error_object` 域的 `PrototypeMethod.stack_getter`，setter length 1、对应 `stack_setter`，flags 不可写 / 不可枚举 / 可配置，realm global 传入的 `global`。
- **所有权 / 错误 / 调用**：建一对 `get stack` / `set stack` 函数对象并写成访问器（setter 名由 `defineLazyNativeAccessorPairAtom` 在 128 字节栈缓冲里拼出来），两个都盖 `.error_object` 域的记录 id。reserve 的 1 只覆盖这一条属性；`Error.prototype` 的 `name` / `message` 是 `defineConstructor` 装的。错误：取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1593`）的 `.error_` 分支。

### `installPromiseExtras` (`src/exec/standard_globals.zig:2896`)

- **签名**：`fn installPromiseExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装 `Promise[Symbol.species]`，并把 `Promise.prototype` 与 `Promise` 构造器本身缓存进 realm 槽，使 await / 默认 species 不依赖可变的 `globalThis.Promise`。
- **实现**：构造器预留 1 槽后 `defineLazyNativeGetterAtom` 装 `[Symbol.species]`，getter 名 `"get [Symbol.species]"`、id 为 `.host` 域的 `HostGlobalMethod.species_getter`，flags 不可写 / 不可枚举 / 可配置；`global.setCachedPromiseProto(rt, constructorPrototypeObject(ctor))` 存原型；`setCachedRealmValue(.promise_constructor, ctor.value())` 对标 qjs 的 `ctx->promise_ctor`（`JS_AddIntrinsicPromise`，quickjs.c:54663）。缺预定义 symbol atom 时 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：除了建一个 `get [Symbol.species]` 函数对象，还往 realm 里写两条**长期**引用：`setCachedPromiseProto` 存原型、`setCachedRealmValue(.promise_constructor, ctor.value())` 存构造器——源码注释点明这是对标 qjs `ctx->promise_ctor`，让 await / 默认 species 不依赖可变的 `globalThis.Promise`。这两条槽是 realm 的 GC 根，构造器/原型从此由 realm 持有。错误：`error.InvalidBuiltinRegistry`（取不到 `Symbol.species` atom）+ 分配失败。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1591`）。

### `installIteratorExtras` (`src/exec/standard_globals.zig:2907`)

- **签名**：`fn installIteratorExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：在 `Iterator.prototype` 上装 `[Symbol.iterator]`（返回 this）、`[Symbol.dispose]`，以及 `constructor` 与 `[Symbol.toStringTag]` 两对「带防污染 setter」的访问器。
- **实现**：取 `.prototype` 并预留 4 槽。`[Symbol.iterator]` 用 `iterator_identity_method`、`[Symbol.dispose]`（`core.atom.ids.Symbol_dispose`）用 `iterator_dispose_auto_init` 装成 AUTOINIT，flags 取 `method_flags`（可写 / 不可枚举 / 可配置）。`constructor` 与 `[Symbol.toStringTag]` 各走一次 `defineLazyNativeAccessorPairAtom`，分别绑 `.iterator` 域的 `AccessorMethod.constructor_getter` / `constructor_setter` 与 `to_string_tag_getter` / `to_string_tag_setter`，setter length 均为 1，flags 不可写 / 不可枚举 / 可配置——spec 要求这两条是带 setter 的访问器而不是数据属性，具体的接收者判定在 `.iterator` 域的 setter 实现里。
- **所有权 / 错误 / 调用**：四条属性：`[Symbol.iterator]` 与 `[Symbol.dispose]` 写静态描述符（`iterator_identity_method` / `iterator_dispose_auto_init`）的借用指针不建对象；`constructor` 与 `[Symbol.toStringTag]` 各建一对 getter/setter 函数对象——Iterator 的 `constructor` 是访问器而不是数据属性，这也是 `prototypeOwnPropertyCapacity` 注释里「constructor, as data property or Iterator accessor」那句的由来。reserve 的 4 与实际条数对齐。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1613`）。

### `installStringPrototypeAliases` (`src/exec/standard_globals.zig:2943`)

- **签名**：`fn installStringPrototypeAliases(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：补 `String.prototype` 上方法表装不了的四条：`length` 常量 0、AnnexB 别名 `trimLeft` / `trimRight`、以及 `[Symbol.iterator]`。
- **实现**：取 `.prototype`（缺则 `error.InvalidBuiltinRegistry`）并预留 4 槽；`defineDataAtom(length, int32(0), {writable=false, enumerable=false, configurable=true})`；两次 `installNativeMethodAlias`（`trimStart`→`trimLeft`、`trimEnd`→`trimRight`，会把这两个源方法提前物化）；最后用 `string_iterator_auto_init` 以 `method_flags` 把 `[Symbol.iterator]` 装成 AUTOINIT。
- **所有权 / 错误 / 调用**：四条：`length` 是数据属性（走查重版 `defineDataAtom`）；`trimLeft` / `trimRight` 两条别名会 `getProperty` 物化出 `trimStart` / `trimEnd` 的函数对象再共享同一对象；`[Symbol.iterator]` 写静态描述符 `string_iterator_auto_init`。不新建函数对象（别名复用已有的）。错误：取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1576`）的 `.string` 分支。

### `defineObjectPrototypeMethodsAssumingNew` (`src/exec/standard_globals.zig:2953`)

- **签名**：`fn defineObjectPrototypeMethodsAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object) !void`。
- **作用**：装 `Object.prototype` 的方法表，并在表的第 6 条之后插入 `__proto__` 的 getter / setter 对，以保持与 qjs 一致的属性顺序。
- **实现**：先 `defineNativeMethodsAssumingNewWithRealm(proto, object_prototype[0..6], global)` 装前 6 条；再 `defineLazyNativeAccessorPairAtom(proto, core.atom.ids.__proto__, "get __proto__", 0, 1, 0, {false,false,true}, global)`——两个 native id 都传 0，即这对访问器不盖记录、调用时仍按名字分发；最后把 `object_prototype[6..]` 余下的条目装完。
- **所有权 / 错误 / 调用**：把 `object_prototype` 表切成 `[0..6]` 与 `[6..]` 两段铺 AUTOINIT，中间插 `__proto__` 访问器对——切分点是为了让 `__proto__` 落在 QuickJS 的属性顺序位上。`__proto__` 那对 getter/setter 的 native id 都传 0（**没有记录 id**，靠 `Object.prototype.__proto__` 的名字级联分发），是本文件里唯一这么做的访问器对。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `defineConstructor`（`src/exec/standard_globals.zig:1344`）的 `kind == .object` 分支。

### `installPerformance` (`src/exec/standard_globals.zig:2962`)

- **签名**：`fn installPerformance(rt: *core.JSRuntime, global: *core.Object) !void`。
- **作用**：在 global 上把 `performance` 装成 AUTOINIT 占位，真正带 `now` 的对象要到第一次读 `globalThis.performance` 时才由 `materializePerformanceAutoInit` 建。
- **实现**：`core.atom.predefinedId("performance", .string)` 取键，flags 用 `global_flags`（可写 / 不可枚举 / 可配置），描述符 `&performance_auto_init`，realm global 传 `global` 自身，一次 `global.defineAutoInitPropertyFromDescriptor`。
- **所有权 / 错误 / 调用**：一条 AUTOINIT 属性，槽里存静态描述符 `performance_auto_init` 的借用指针，`performance` 对象本身到首次读才建；flags 取 `global_flags`（可写、不可枚举、可配置）。不分配、没有额外所有权。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardGlobals`（`src/exec/standard_globals.zig:1750`）。

### `installNavigator` (`src/exec/standard_globals.zig:2968`)

- **签名**：`fn installNavigator(rt: *core.JSRuntime, global: *core.Object) !void`。
- **作用**：在 global 上把 `navigator` 装成 AUTOINIT 占位；物化后（`materializeNavigatorAutoInit`）是一个自身无属性的对象，`userAgent` getter 与 `@@toStringTag` 都挂在它的原型上。
- **实现**：与 `installPerformance` 同形，唯一差别是 flags 不用 `global_flags` 而是写死 `core.property.Flags.data(false, true, true)`：不可写、**可枚举**、可配置；描述符是 `&navigator_auto_init`。
- **所有权 / 错误 / 调用**：同 `installPerformance`，但 flags 是**手写**的 `core.property.Flags.data(false, true, true)`（不可写、可枚举、可配置）而不是 `global_flags`——`navigator` 是 global 上少见的可枚举属性。槽存静态描述符 `navigator_auto_init` 的借用指针。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardGlobals`（`src/exec/standard_globals.zig:1751`）。

### `installRegExpExtras` (`src/exec/standard_globals.zig:2974`)

- **签名**：`fn installRegExpExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装 `RegExp` 里方法表覆盖不到的全部内容：构造器上的 `escape` 与 `[Symbol.species]`、原型上的五个 `@@` 符号方法与十个 flag 只读访问器，最后转 19 条 AnnexB legacy 静态访问器。
- **实现**：构造器先预留 21 槽（与 `constructorExtraPropertyCount(.regexp)` 对齐），用 `regexp_escape_auto_init` 把 `RegExp.escape` 装成 AUTOINIT（realm global 传 null）。原型再预留 `regexp_symbol_auto_init.len + 10` 槽，`bootstrapPropertyRealm` 解析一次 realm 后循环把 `regexp_symbol_auto_init` 的五条（`Symbol.match` / `matchAll` / `replace` / `search` / `split`，length 依次 1/1/2/1/2）按 `predefinedId(method.symbol, .symbol)` 装成 AUTOINIT。随后本地 10 元表装 `source` / `flags` / `global` / `ignoreCase` / `multiline` / `dotAll` / `unicode` / `sticky` / `hasIndices` / `unicodeSets` 只读 getter，id 由 `regexp_builtin.accessorMethodId` 查（查不到给 0），flags 不可写 / 不可枚举 / 可配置。最后给构造器装 `.host` 域的 `[Symbol.species]` getter，并调 `installRegExpLegacyAccessors`。
- **所有权 / 错误 / 调用**：本文件最重的一个 extras：构造器侧 reserve 21 槽装 `escape` 的 AUTOINIT（realm 传 null）加 `[Symbol.species]` 加 19 条 legacy 访问器；原型侧 reserve `regexp_symbol_auto_init.len + 10`，先铺 `@@match`/`@@replace` 等 symbol 方法的 AUTOINIT（复用一次解析好的 realm），再建 10 个 flag getter 函数对象。`regexp_builtin.accessorMethodId` 查不到时 native id 静默填 0（退回名字级联），atom 查不到才 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1589`）的 `.regexp` 分支。

### `installRegExpLegacyAccessors` (`src/exec/standard_globals.zig:3025`)

- **签名**：`fn installRegExpLegacyAccessors(rt: *core.JSRuntime, ctor: *core.Object) !void`。
- **作用**：在 `RegExp` 构造器上装 19 条 AnnexB 静态访问器：`input`/`$_`、`lastMatch`/`$&`、`lastParen`/`$+`、`leftContext`/`` $` ``、`rightContext`/`$'` 与 `$1`–`$9`。
- **实现**：本地 19 元表逐条给出 (name, getter_name, getter `LegacyAccessorMethod`, 可选 setter)：只有 `input` 与 `$_` 带 `set_input`，其余 17 条是只读；长名与 `$x` 短名成对共用同一个 getter 方法（如 `lastMatch` 与 `$&` 都是 `get_last_match`）。先 `reserveOwnPropertyCapacityAssumingPlain(prop_count + 19)`，再逐条 `defineRegExpLegacyAccessor`，flags 统一不可写 / 不可枚举 / 可配置。
- **所有权 / 错误 / 调用**：只做一次 reserve（19 条）加循环转发，自身不分配；19 个名字里 `$_`、`$&`、`` $` ``、`$'`、`$1`..`$9` 全不是预定义 atom，实际的 intern 发生在 `defineRegExpLegacyAccessor` 里。只有 `input` / `$_` 两条带 setter，因此这一趟共建 19 个 getter + 2 个 setter 函数对象。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installRegExpExtras`（`src/exec/standard_globals.zig:3039`）。

### `defineRegExpLegacyAccessor` (`src/exec/standard_globals.zig:3059`)

- **签名**：`fn defineRegExpLegacyAccessor( rt: *core.JSRuntime, ctor: *core.Object, name: []const u8, getter_name: []const u8, getter_method: regexp_builtin.LegacyAccessorMethod, setter_method: ?regexp_builtin.LegacyAccessorMethod, flags: Flags, ) !void`。
- **作用**：装一条 RegExp legacy 静态访问器：按有没有 setter 决定装访问器对还是只读 getter。
- **实现**：`ctor.nativeFunctionRealmGlobalPtr()` 取构造器所属 realm 的 global（拿不到即 `error.InvalidBuiltinRegistry`），作为后续两个 helper 的显式 realm。键走 `temporaryStringAtom(rt, name)` 而不是 `predefinedId` 常量——`$&`、`` $` ``、`$'` 这些名字不在预定义 atom 表里，需要 intern；`defer freeTemporaryStringAtom` 配对。getter id 由 `core.function.nativeBuiltinId(.regexp, @intFromEnum(getter_method))` 编码；有 setter 就走 `defineLazyNativeAccessorPairAtom`（setter length 1，setter id 同样这样编码），否则走 `defineLazyNativeGetterAtomWithRealm` 装只读 getter。
- **所有权 / 错误 / 调用**：键走本文件统一的 `temporaryStringAtom`/`freeTemporaryStringAtom` 协议（TGC S3 §4 class B）：非预定义名 intern 后立刻 `pinForHost`，跨过随后会分配的 define 调用，由 `defer` 解 pin，属性表接管后不再需要这个 host pin。`realm_global` 从 `ctor.nativeFunctionRealmGlobalPtr()` 借出，取不到即 `error.InvalidBuiltinRegistry`。有 setter 的走 `defineLazyNativeAccessorPairAtom`（建两个函数对象），否则 `defineLazyNativeGetterAtomWithRealm`（建一个）。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installRegExpLegacyAccessors`（`src/exec/standard_globals.zig:3072`）。

### `installNativeMethodAlias` (`src/exec/standard_globals.zig:3089`)

- **签名**：`fn installNativeMethodAlias(rt: *core.JSRuntime, proto: *core.Object, target: []const u8, alias: []const u8) !void`。
- **作用**：把一个已装好的方法再以另一个名字发布一份（同一个函数对象），用于 `toGMTString`、`trimLeft`、`trimRight` 这类 AnnexB 别名。
- **实现**：两次 `temporaryStringAtom` 分别取目标名与别名的 atom（各自 defer 释放），转 `publishMethodAlias(rt, proto, proto, target_key, alias_key, false)`：后者读一次源属性（源若是 AUTOINIT 会在此物化成真函数对象），再以 `method_flags` 走 `defineOwnPropertyAssumingNew` 写别名键。`replace_existing_auto_init = false` 表示别名键必须是新的。
- **所有权 / 错误 / 调用**：两个名字 atom 各自 `temporaryStringAtom` + `defer freeTemporaryStringAtom` 配对；不建函数对象，`publishMethodAlias` 会把原名的（可能刚被物化出来的）函数对象共享给别名。`replace_existing_auto_init` 传 false，所以别名必须是新键。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 3 个调用方：`defineDatePrototypeMethodsAssumingNew`（`src/exec/standard_globals.zig:2852`，toUTCString→toGMTString）、`installStringPrototypeAliases`（2964/2965，trimStart→trimLeft、trimEnd→trimRight）。

### `installCollectionExtras` (`src/exec/standard_globals.zig:3097`)

- **签名**：`fn installCollectionExtras(rt: *core.JSRuntime, global: *core.Object, name: []const u8, ctor: *core.Object) !void`。
- **作用**：四种集合（`Map` / `Set` / `WeakMap` / `WeakSet`）构造器安装完之后的收尾：按名字补 species、补需要穿插 `size` 访问器的原型方法，并统一装原型上的迭代器别名与 `@@toStringTag`。
- **实现**：按集合名分支：Map / Set 先装 `Symbol.species`，再取原型走 `defineCollectionPrototypeMethodsAssumingNew`（WeakMap / WeakSet 的原型方法在 `defineConstructor` 主路径已装）；最后所有四种都走 `installCollectionPrototypeSymbols`。缺原型返回 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：自身不分配，只按名字分派：Map/Set 多走 `installCollectionSpecies`（建 species getter）与 `defineCollectionPrototypeMethodsAssumingNew`（铺原型方法 + size 访问器），四种集合都走 `installCollectionPrototypeSymbols`。注意 `std.mem.eql(name, "Map") or ..."Set"` 判了两次（第一次给 species、第二次给原型方法），中间隔着一次 `constructorPrototypeObject`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1631`），名字由 `collectionNameForKind(kind)` 给出。

### `installCollectionSpecies` (`src/exec/standard_globals.zig:3106`)

- **签名**：`fn installCollectionSpecies(rt: *core.JSRuntime, ctor: *core.Object) !void`。
- **作用**：在 `Map` / `Set` 构造器上装 `[Symbol.species]` getter（返回 this），`WeakMap` / `WeakSet` 按 spec 没有这条。
- **实现**：取预定义 symbol atom（缺则 `error.InvalidBuiltinRegistry`），预留 1 槽后 `defineLazyNativeGetterAtom`：getter 名 `"get [Symbol.species]"`、id 为 `.host` 域的 `HostGlobalMethod.species_getter`，flags 不可写 / 不可枚举 / 可配置，realm 由构造器自身推。
- **所有权 / 错误 / 调用**：建一个 `get [Symbol.species]` 函数对象（`(.host, species_getter)` 记录 id），reserve 1 槽。与紧挨着的 `installTypedArraySpecies`（3128）**逐字节相同**，只是调用方不同。错误：取不到 `Symbol.species` atom 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installCollectionExtras`（`src/exec/standard_globals.zig:3114`）。

### `installTypedArraySpecies` (`src/exec/standard_globals.zig:3112`)

- **签名**：`fn installTypedArraySpecies(rt: *core.JSRuntime, ctor: *core.Object) !void`。
- **作用**：给抽象的 `%TypedArray%` 构造器装 `[Symbol.species]`（12 个具体 TypedArray 构造器以它为 `__proto__`，沿原型链继承这一条，不各装一份）。
- **实现**：函数体与 `installCollectionSpecies` 逐字相同——同一个 `.host` 域 `species_getter` 记录、同样的 flags 与预留一槽；拆成两个名字只是为了让 `installTypedArrayIntrinsicExtras` 与 `installCollectionExtras` 两处调用点读起来对应各自的 kind。
- **所有权 / 错误 / 调用**：与上面的 `installCollectionSpecies` 是同一段代码的两份拷贝（同样建一个 species getter、同样 reserve 1 槽），差别只在调用方。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installTypedArrayIntrinsicExtras`（`src/exec/standard_globals.zig:1818`），装在抽象的 `%TypedArray%` 构造器上，12 个具体子类通过原型链继承。

### `installCollectionPrototypeSymbols` (`src/exec/standard_globals.zig:3118`)

- **签名**：`fn installCollectionPrototypeSymbols(rt: *core.JSRuntime, global: *core.Object, name: []const u8, ctor: *core.Object) !void`。
- **作用**：给 `Map` / `Set` / `WeakMap` / `WeakSet` 的原型装迭代器别名与 `[Symbol.toStringTag]`。
- **实现**：按名字预留额外槽（Map / Set 2 条，Weak* 1 条）。Map 把 `entries` 别名成 `@@iterator`；Set 先把 `values` 覆盖到 `keys`（替换占位）再别名成 `@@iterator`；Weak* 不装迭代器。最后用 `collectionTag(name)` 写 `Symbol.toStringTag`，名字未知或缺原型则 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：别名不新建函数：Map 的 `[Symbol.iterator]` 复用 `entries`，Set 的 `keys` 与 `[Symbol.iterator]` 都复用 `values`（`keys` 那条传 `replace_existing_auto_init = true` 覆盖已有占位，`[Symbol.iterator]` 传 false 当新键）。`@@toStringTag` 是静态常量串 AUTOINIT。`extra_count` 对 Map/Set 是 2、WeakMap/WeakSet 是 1，与实际装的条数对齐。错误：`collectionTag(name)` 返回 null 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installCollectionExtras`（`src/exec/standard_globals.zig:3119`）。

### `installNamespaceToStringTag` (`src/exec/standard_globals.zig:3138`)

- **签名**：`fn installNamespaceToStringTag(rt: *core.JSRuntime, global: *core.Object, namespace: *core.Object, tag_name: []const u8) !void`。
- **作用**：给 `Math` / `JSON` / `Reflect` / `Atomics` 这四个命名空间对象装 `[Symbol.toStringTag]` 字符串常量。
- **实现**：单行转 `defineStringConstantAtomAssumingNewWithRealm`：键是预定义 symbol atom `"Symbol.toStringTag"`，值是 `tag_name`（"Math" / "JSON" / "Reflect" / "Atomics" 之一，必须在 `standard_string_auto_init` 表里），flags 不可写 / 不可枚举 / 可配置，realm global 为 `global`。走 AssumingNew，因此要求命名空间对象上还没有这个键。
- **所有权 / 错误 / 调用**：单行转发，槽里是静态常量串描述符的借用指针，不分配。**跑在 AUTOINIT 物化路径上**：四个调用方全在 `materializeBuiltinNamespaceAutoInit`（`src/exec/standard_globals.zig:1097` Math、1100 JSON、1104 Reflect、1107 Atomics），首次读 `globalThis.Math` 之类时触发，`tag_name` 不在 `standard_string_auto_init` 表里会以 `error.InvalidBuiltinRegistry` 变成一次属性读失败、抛 JS 异常。

### `installPrototypeToStringTag` (`src/exec/standard_globals.zig:3142`)

- **签名**：`fn installPrototypeToStringTag(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8, ctor: *core.Object) !void`。
- **作用**：给某个构造器的 `.prototype` 装 `[Symbol.toStringTag]` 字符串常量（今天只有 `installDOMExceptionExtras` 用它）。
- **实现**：比 `installNamespaceToStringTag` 只多一步 `constructorPrototypeObject(rt, ctor)` 取 `.prototype`（缺失即 `error.InvalidBuiltinRegistry`），其余参数与它完全一致。
- **所有权 / 错误 / 调用**：比 `installNamespaceToStringTag` 多一步取 `.prototype`（取不到即 `error.InvalidBuiltinRegistry`），同样不分配。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 两个调用方：`installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1624`，BigInt / Promise / WeakRef / FinalizationRegistry 四 kind 共用一条）与 `installDOMExceptionExtras`（3218）。

### `installDisposableStackExtras` (`src/exec/standard_globals.zig:3147`)

- **签名**：`inline fn installDisposableStackExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装 `DisposableStack` 原型上的三条：`disposed` getter、把 `dispose` 再发布成 `[Symbol.dispose]`、以及 `@@toStringTag` = "DisposableStack"。
- **实现**：转发 `installDisposableStackCtorExtras`：`disposable_stack_method = 6` 的 `disposed` getter、`dispose`→`[Symbol.dispose]` 别名、tag "DisposableStack"。
- **所有权 / 错误 / 调用**：`inline fn`，只摆参数转给 `installDisposableStackCtorExtras`（`src/exec/standard_globals.zig:3193`）：那边 reserve 3 槽，建一个 `get disposed` 函数对象（metadata 带 `disposable_stack_method = 6`，方法号 6 是运行时区分两种栈的依据）、发布别名 `dispose` → `[Symbol.dispose]`、写 `@@toStringTag = "DisposableStack"`。取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1618`）。

### `installAsyncDisposableStackExtras` (`src/exec/standard_globals.zig:3159`)

- **签名**：`inline fn installAsyncDisposableStackExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：`AsyncDisposableStack` 的同形安装：`disposed` getter、`disposeAsync` → `[Symbol.asyncDispose]` 别名、`@@toStringTag` = "AsyncDisposableStack"。
- **实现**：转发 `installDisposableStackCtorExtras`：`async_disposable_stack_method = 6` 的 `disposed` getter、`disposeAsync`→`[Symbol.asyncDispose]` 别名、tag "AsyncDisposableStack"。
- **所有权 / 错误 / 调用**：`inline fn`，只摆参数转给 `installDisposableStackCtorExtras`（`src/exec/standard_globals.zig:3193`）：那边 reserve 3 槽，建一个 `get disposed` 函数对象（metadata 带 `async_disposable_stack_method = 6`，方法号 6 是运行时区分两种栈的依据）、发布别名 `disposeAsync` → `[Symbol.asyncDispose]`、写 `@@toStringTag = "AsyncDisposableStack"`。取不到 `.prototype` 时 `error.InvalidBuiltinRegistry`。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1619`）。

### `installDisposableStackCtorExtras` (`src/exec/standard_globals.zig:3177`)

- **签名**：`noinline fn installDisposableStackCtorExtras( rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object, disposed_metadata: NativeFunctionMetadata, alias_from: core.Atom, alias_to: core.Atom, tag: []const u8, ) !void`。
- **作用**：DisposableStack / AsyncDisposableStack 共用 extras：原型预留、`disposed` getter、dispose 别名、`Symbol.toStringTag`。
- **实现**：缺原型 → `InvalidBuiltinRegistry`。`reserveOwnPropertyCapacityAssumingPlain(+3)`。`defineLazyNativeGetterAtomWithRealmAndMetadata` 装 `disposed`。`publishMethodAlias(proto, proto, alias_from, alias_to, false)`。再 toStringTag。outlined leftover：方法 tag、别名 atom、tag 字符串作运行时参数。不折 Error/Iterator extras。
- **所有权 / 错误 / 调用**：`installDisposableStackExtras` / `installAsyncDisposableStackExtras` 是 inline 包装（同步 `Symbol.dispose` vs 异步 `Symbol.asyncDispose`）。

### `installDOMExceptionExtras` (`src/exec/standard_globals.zig:3201`)

- **签名**：`fn installDOMExceptionExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void`。
- **作用**：装 `DOMException` 的 `@@toStringTag` 和 25 条历史错误码常量，构造器与原型上各挂一份（`INDEX_SIZE_ERR` = 1 … `DATA_CLONE_ERR` = 25）。
- **实现**：先 `installPrototypeToStringTag(..., "DOMException", ctor)`；取 `.prototype`（缺则 `error.InvalidBuiltinRegistry`）；构造器与原型各 `reserveOwnPropertyCapacityAssumingPlain(prop_count + dom_exception_constants.len)`；随后遍历 `dom_exception_constants`（`INDEX_SIZE_ERR` = 1 一直到 `DATA_CLONE_ERR` = 25），每条在两个对象上各 `defineDataAssumingNew(name, core.JSValue.int32(code), flags)`，flags 是不可写 / **可枚举** / 不可配置——这里的 enumerable 与本文件其它安装路径相反。
- **所有权 / 错误 / 调用**：先装 `@@toStringTag`，再给构造器与原型**各**铺一遍 `dom_exception_constants`（同一批数字常量装两份，这是 DOMException 的 legacy 要求），flags 是罕见的 `{writable=false, enumerable=true, configurable=false}`。两边各 reserve 一次，条数与 `constructorExtraPropertyCount(.dom_exception)` / `prototypeExtraPropertyCount(.dom_exception)` 对齐。不分配对象；名字 atom 由 `defineDataAssumingNew` 内部 pin/unpin。错误集由 Zig 推断（`error.OutOfMemory` 与本文件 `return` 的 `error.InvalidBuiltinRegistry`），`try` 上抛到 `installStandardGlobals` 再由 `JSRuntime.installStandardGlobals`（`src/core/runtime.zig:4303`）`@errorCast` 成 `errors.RuntimeError`，失败即回滚 realm 让 context 创建失败——**不经 `materializeRuntimeError`，不变成 JS 异常**。 唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1616`）。

### `collectionTag` (`src/exec/standard_globals.zig:3213`)

- **签名**：`fn collectionTag(name: []const u8) ?[]const u8`。
- **作用**：集合名到它 `Symbol.toStringTag` 字符串的映射。
- **实现**：四个 `std.mem.eql` 分支返回同名字符串（Map/Set/WeakMap/WeakSet），未知返回 null。
- **所有权 / 错误 / 调用**：无：四条 `std.mem.eql` 返回静态字符串字面量的借用切片，不分配、无 error set，未命中 null。唯一调用方 `installCollectionPrototypeSymbols`（`src/exec/standard_globals.zig:3151`），`orelse return error.InvalidBuiltinRegistry`。返回值恒等于入参，存在的意义只是把「哪些名字算集合」这个白名单收在一处。

### `collectionNameForKind` (`src/exec/standard_globals.zig:3221`)

- **签名**：`fn collectionNameForKind(kind: ConstructorKind) ?[]const u8`。
- **作用**：把 Map/Set/WeakMap/WeakSet 的 `ConstructorKind` 映射回集合名，其余 kind 返回 null。
- **实现**：四臂 switch：`.map`→"Map"、`.set`→"Set"、`.weak_map`→"WeakMap"、`.weak_set`→"WeakSet"，`else => null`。返回的字面量正是 `collectionTag` / `collectionPrototypeMethods` / `installCollectionExtras` 再按名字分派时用的键，所以这四个串必须与那几处的 `std.mem.eql` 比较保持一致。
- **所有权 / 错误 / 调用**：无：`ConstructorKind` → 静态字符串字面量的查表，不分配、无 error set。唯一调用方 `installStandardConstructorWithPrototype`（`src/exec/standard_globals.zig:1631`），返回 null 就跳过整个集合 extras。

### `collectionPrototypeMethods` (`src/exec/standard_globals.zig:3231`)

- **签名**：`fn collectionPrototypeMethods(name: []const u8) ?[]const Method`。
- **作用**：集合名到对应原型方法表的映射。
- **实现**：四个 `std.mem.eql` 分支返回 `map_prototype` / `set_prototype` / `weak_map_prototype` / `weak_set_prototype`，未知返回 null。
- **所有权 / 错误 / 调用**：无：按名字返回四张静态 `Method` 表之一的借用切片，不分配、无 error set。返回的切片元素地址会被写进 AUTOINIT 槽，所以必须是这些 `const` 全局表而不是临时值。唯一调用方 `defineCollectionPrototypeMethodsAssumingNew`（`src/exec/standard_globals.zig:1909`）的 else 臂（今天只有 WeakMap / WeakSet 走得到）。

### `Intrinsics.init` (`src/exec/standard_globals.zig:3243`)

- **签名**：`pub fn init(rt: *core.JSRuntime) !Intrinsics`。
- **作用**：测试 / 嵌入手柄：`configureRuntime` + 建 `JSContext` + 建 global object + `rt.installStandardGlobals`。
- **实现**：四步顺序装配：`configureRuntime(rt)` 把安装器与容量钉进 runtime；`core.JSContext.create(rt)` 建 context 并 `errdefer context.destroy()`；`core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.global_object, null, standardGlobalOwnPropertyCapacity())` 建一个**无原型**的 global（原型稍后由 `Object.prototype` 安装补上），`ensureGlobalPayload` 给它挂上 global payload；把 `context.global` 指过去后 `rt.installStandardGlobals(global)` 跑完整安装，最后返回 `{context, global}`。顺序不能换：global payload 必须在安装器发布任何 realm 相关的 AUTOINIT 槽之前就位。
- **所有权 / 错误 / 调用**：`errdefer context.destroy()` 只护住 context 创建之后到返回之间的失败；global 对象不单独释放（归 GC）。返回的 `Intrinsics` 持 context 与 global 两个借用指针，`deinit` 只销毁 context。错误：`JSContext.create` / 建对象的 `error.OutOfMemory`，以及 `rt.installStandardGlobals` 收窄后的 `errors.RuntimeError`——都直接变成测试失败，不进 JS 异常通道。调用方全是本文件的 5 个测试（`src/exec/standard_globals.zig:3497`、3538、3583 等，每处后面跟一句 `defer intrinsics.deinit(rt)`）。

### `Intrinsics.deinit` (`src/exec/standard_globals.zig:3259`)

- **签名**：`pub fn deinit(self: *Intrinsics) void`（原先恒被丢弃的 `rt` 形参已删）。
- **作用**：释放该结构持有的根 / 缓冲。
- **实现**：只 `self.context.destroy()`，global 随 runtime 回收。
- **所有权 / 错误 / 调用**：**global 对象不在这里释放**，它由 context 销毁时连同 realm 一起走 GC。无 error set。唯一调用方是本文件的测试：每个 `Intrinsics.init` 后面跟一句 `defer intrinsics.deinit()`（`src/exec/standard_globals.zig:3498`、3539、3584 等共 5 处）。

### `methodDescriptor` (`src/exec/standard_globals.zig:3264`)

- **签名**：`fn methodDescriptor(methods: []const Method, name: []const u8) ?*const Method`。
- **作用**：文件末 comptime 自检用：在一张 `Method` 表里按名字线性找描述符。
- **实现**：线性 `std.mem.eql`，命中返回元素指针，未命中 null。
- **所有权 / 错误 / 调用**：无：纯 comptime，不分配、无 error set。 返回静态 `Method` 表元素的借用指针。7 个调用点全在紧随其后的 `comptime` 块（`src/exec/standard_globals.zig:3289-3314`）里，用来断言 `preparedMethods` 盖上的 `native_builtin_id` / marker 与各 `*_builtin` 模块的 id 表一致；查不到就 `@compileError`。

### `getNamedPropertyForTest` (`src/exec/standard_globals.zig:3425`)

- **签名**：`fn getNamedPropertyForTest(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !core.JSValue`。
- **作用**：单测辅助：按字符串名从对象上读一个属性值（读的过程会把 AUTOINIT 占位物化）。
- **实现**：`temporaryStringAtom(rt, name)` 取 atom 并 `defer freeTemporaryStringAtom`，转 `object.getProperty(key)`；不做任何断言，仅供下面几个 expect* 辅助复用。
- **所有权 / 错误 / 调用**：测试专用。名字 atom 由 `temporaryStringAtom` pin、`defer` 归还；`getProperty` 会触发 AUTOINIT 物化，返回的值由属性表持有（测试里不额外 root，因为紧接着就用完）。错误是 `getProperty` 的 `PropertyReadError` 加 intern 的分配失败，在测试里被 `try` 变成测试失败，**不进 JS 异常通道**。6 个调用方全是本文件测试与 `getConstructorPrototypeForTest`（3471）。

### `expectNativeAliasForTest` (`src/exec/standard_globals.zig:3431`)

- **签名**：`fn expectNativeAliasForTest( _: *core.JSRuntime, source_owner: *core.Object, source_atom: core.Atom, alias_owner: *core.Object, alias_atom: core.Atom, domain: core.function.NativeBuiltinDomain, id: u32, ) !void`。
- **作用**：单测断言：源属性与别名属性必须是**同一个**函数对象，且它带指定 domain/id 的 native 记录——用来守住 `toGMTString`、`trimLeft`、`@@iterator` 这类别名没有退化成两份拷贝。
- **实现**：两侧各 `getProperty` 取值后 `source.sameValue(alias)`；再对源值 `expectObjectAssumeBootstrap` 解包，`expectEqual(core.function.nativeBuiltinId(domain, id), function_object.nativeFunctionId())`，并断言 `function_object.nativeEntry() != null`（记录已解析到 `NativeEntry`）。首参 `rt` 用 `_` 丢弃。
- **所有权 / 错误 / 调用**：测试专用断言：两次 `getProperty` 取值（会物化 AUTOINIT），断言 `sameValue`（别名与原名必须是**同一个函数对象**，不是等价副本）、`nativeFunctionId()` 等于期望的 `(domain, id)`、且 `nativeEntry() != null`。`rt` 参数用 `_:` 丢弃。错误是 `PropertyReadError` 加 `std.testing` 的断言失败。5 个调用方全是本文件测试（`src/exec/standard_globals.zig:3590`、3608、3621 等）。

### `getConstructorPrototypeForTest` (`src/exec/standard_globals.zig:3449`)

- **签名**：`fn getConstructorPrototypeForTest( rt: *core.JSRuntime, global: *core.Object, constructor_name: []const u8, ) !core.JSValue`。
- **作用**：单测辅助：从 global 上按名字取构造器，再读它的 `.prototype`。
- **实现**：`getNamedPropertyForTest(rt, global, constructor_name)` 取构造器值，`expectObjectAssumeBootstrap` 直接解包（构造器不存在会在这里的 `.?` 上 panic，而不是返回 error），再 `getProperty(core.atom.ids.prototype)`。
- **所有权 / 错误 / 调用**：测试专用：先 `getNamedPropertyForTest` 取构造器（名字 atom 在那边配对），再无检查 `expectObjectAssumeBootstrap` 解包并读 `.prototype`。构造器不是对象会命中 `.?` 的 unreachable 而不是报错。6 个调用方全是本文件测试（`src/exec/standard_globals.zig:3671`、3680、3682、3751、3762、3788）。

### `expectNativeFunctionForTest` (`src/exec/standard_globals.zig:3458`)

- **签名**：`fn expectNativeFunctionForTest( _: *core.JSRuntime, owner: *core.Object, atom_id: core.Atom, domain: core.function.NativeBuiltinDomain, id: u32, ) !void`。
- **作用**：单测断言：某个 atom 键下的属性是函数对象，且带指定 domain/id 的 native 记录。
- **实现**：`owner.getProperty(atom_id)`（会物化 AUTOINIT）后 `expectObjectAssumeBootstrap` 解包，比对 `nativeFunctionId()` 与 `core.function.nativeBuiltinId(domain, id)`，再断言 `nativeEntry() != null`。首参 `rt` 用 `_` 丢弃。
- **所有权 / 错误 / 调用**：测试专用：`getProperty` 物化后断言 `nativeFunctionId()` 与 `nativeEntry() != null`，`rt` 参数丢弃。比 `expectNativeAliasForTest` 少了别名同一性那条。只有 2 个调用方，都在同一个测试里（`src/exec/standard_globals.zig:3677`/3678，验 `String.prototype.toString` / `valueOf` 的 `(.primitive, 51/52)`）。

### `expectAutoInitOwnPropertyForTest` (`src/exec/standard_globals.zig:3471`)

- **签名**：`fn expectAutoInitOwnPropertyForTest(object: *core.Object, atom_id: core.Atom) !void`。
- **作用**：单测断言：某个属性**仍然**是尚未物化的 AUTOINIT 占位，用来证明 lazy 安装没有被提前触发。
- **实现**：`object.findProperty(atom_id)` 找不到即 `error.TestUnexpectedResult`；找到则 `expectEqual(core.property.Kind.auto_init, object.propKindAt(property_index))`。刻意走 `findProperty` + `propKindAt` 而不是 `getProperty`，否则断言自身就会把占位物化掉。
- **所有权 / 错误 / 调用**：测试专用，也是本册唯一一个**不触发物化**的断言：只 `findProperty` 拿下标再看 `propKindAt` 是不是 `.auto_init`，属性缺失返回 `error.TestUnexpectedResult`。不分配、不读值。唯一调用方在 `src/exec/standard_globals.zig:3825` 的测试循环，用来证明 global 上那批方法在被读之前确实还是 AUTOINIT 占位。


## `src/exec/builtin_dispatch.zig` — NativeEntry 分发

typed 桥：exec 的 native 调用点 ↔ `rt.internal_builtins`。QuickJS 对照是 `JS_CallInternal` 里对 `JSCFunctionListEntry` 的分发。

`NativeEntry` 只持 cproto 标记的函数指针；realm、host output、VM caller **不**进 core ABI，而在栈上的 `NativeCallEnvironment`，经 `runtime.active_native_call` 发布。handler 用 `nativeCall()` 拼回。

分发分层（设计 NB2 / native-boundary）：

| 路径 | 入口 | 用途 |
| --- | --- | --- |
| VM window, `!needs_env` | `callManagedFromWindow` / `callRecordFromVmInRealm` | 热：backtrace + 一次 `bl` |
| K2 method_leaf | `invokeMethodLeafFast` | 接收者 class/`prim_self` + 无强制转换 marshal |
| K1 leaf | `invokeLeafFast` | Math.abs 这类 f64/i32 标签命中 |
| rooted / 冷 | `callInternalRecordDirect` | ValueRootFrame + environment |
| construct | `callConstructRecordImpl` | `is_constructor=true`，`new_target`=实例原型 |

失败模型：native 返回 16 字节 `JSValue`；`tag==exception` 当且仅当 pending exception 已设（对照 `JS_EXCEPTION`）。Zig `HostError` 在边界收成 sentinel。

### 类型

- `NativeValue` / `NativeBits`：16B JSValue 与 x0+x1 整数覆盖。
- `VmCallerView`：output + caller bytecode/frame，无 environment 时从 active invocation 读。
- `CallRealmView`：一次可观察调用的原子权威（realm + 其 global）。
- `NativeCallEnvironment` / `NativeCall`：栈上 exec 视图。
- `NativeBacktraceScope`：对标 qjs `JSStackFrame`，错误栈能看到 native callee。
- `NativeAccessorTarget` / `TypedSetterOutcome`：K3 访问器快路径。


### `nativeToBits` (`src/exec/builtin_dispatch.zig:32`)

- **签名**：`pub inline fn nativeToBits(v: NativeValue) NativeBits`。
- **作用**：把 16B 的 `NativeValue` 按位转成 x0+x1 的整数覆盖。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：无：`@bitCast` 的重解释，不分配、无 error set、不改变哨兵语义。5 个调用点全在本文件的哨兵返回处：`nativeFromHostError`（`src/exec/builtin_dispatch.zig:65`/73）、`callRecordFromVmInRealm`（642/651）、`callRecordWithEnvironment`（760）。存在的唯一理由写在类型注释里——Zig 的 auto ABI 会给 16B extern `JSValue` 走 sret，等宽无符号整数才落在 x0+x1。

### `nativeFromBits` (`src/exec/builtin_dispatch.zig:36`)

- **签名**：`pub inline fn nativeFromBits(b: NativeBits) NativeValue`。
- **作用**：整数覆盖按位转回 `NativeValue`。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：无：`nativeToBits` 的逆向 `@bitCast`，不分配、无 error set。调用方跨文件：`src/exec/vm_native.zig:65` 收 `callRecordFromVmInRealm` 的返回（另有 `src/tests/exec.zig:18705` 一处测试），其余 8 处都在本文件：`hostResultToValue`（117）、`hostErrorToValue`（122）、`embedderErrorToValue`（135/140/143）、`throwTypeErrorSentinel`（892/895）、`callNativeAccessorTarget`（1078）。

### `nativeExc` (`src/exec/builtin_dispatch.zig:40`)

- **签名**：`pub inline fn nativeExc() NativeValue`。
- **作用**：构造 native 链的异常 sentinel。
- **实现**：返回 `core.JSValue.exception()`。
- **所有权 / 错误 / 调用**：无：返回 `core.JSValue.exception()` 这个常量哨兵，不分配、不写 pending exception——**装异常是调用方的事**（类型注释：failure iff tag==exception 且 `rt.current_exception` 已设）。5 个调用点全在本文件，且每处之前都已确保 `ctx.hasException()`：`nativeFromHostError`（65/73）、`embedderErrorToValue`（139/146）、`throwTypeErrorSentinel`（894）。

### `nativeIsExc` (`src/exec/builtin_dispatch.zig:45`)

- **签名**：`pub inline fn nativeIsExc(ctx: *core.JSContext, v: NativeValue) bool`。
- **作用**：判断 native 返回值是否是异常 sentinel。
- **实现**：取 `v.isException()`，并在 Debug/ReleaseSafe 下断言它与 `ctx.hasException()` 一致。
- **所有权 / 错误 / 调用**：无：读哨兵 tag，不分配、无 error set。副作用是一条 `std.debug.assert(exc == ctx.hasException())`——Debug/ReleaseSafe 下强制「哨兵 ⟺ 有 pending exception」这条不变量（源码 469 行的注释就是靠它）。两个调用方：`src/exec/vm_native.zig:77` 与本文件 `callNativeAccessorTarget`（1079）。注意 `sentinelToHost`（108）**故意不用它**，因为 rooted host 调用允许带着无关的 pending exception 进入。

### `nativeFromHostError` (`src/exec/builtin_dispatch.zig:54`)

- **签名**：`pub noinline fn nativeFromHostError(ctx: *core.JSContext, global: ?*core.Object, err: anyerror) NativeBits`。
- **作用**：叶子/helper 边界适配：把 Zig `anyerror` 物化成 pending JS 异常，返回 exception sentinel 的 `NativeBits`（x0+x1，避免 JSValue sret）。
- **实现**：先 `materializeRuntimeError`（忽略其 error）。若仍无 pending：有 global 则 `createNamedError("Error", @errorName(err))` 再 `throwValue`；创建失败或无 global 走 `installNativeExceptionFallback`。Debug 断言此时必有 pending。`noinline` 把 Error 构造留在 assume 序言之外。不得出现在 NMFD↔assume ABI 上。
- **所有权 / 错误 / 调用**：新 Error 由 `throwValue` 挂到 ctx。`hostErrorToValue` / `hostResultToValue` / `callRecordWithEnvironment` 的失败臂。

### `installNativeExceptionFallback` (`src/exec/builtin_dispatch.zig:76`)

- **签名**：`fn installNativeExceptionFallback(ctx: *core.JSContext) void`。
- **作用**：兜底：在没有 pending 异常时挂上一个，保证「返回 sentinel ⇒ 有 pending」这条不变量成立。
- **实现**：已有 pending 直接返回；否则挂 `ctx.preallocated_oom_error`，连它都没有就 `throwValue(null)`。
- **所有权 / 错误 / 调用**：不分配（预分配值或 null）。`nativeFromHostError` 在无 global 或建 Error 失败时进来。

### `nativeHostError` (`src/exec/builtin_dispatch.zig:99`)

- **签名**：`pub inline fn nativeHostError(ctx: *core.JSContext) HostError`。
- **作用**：哨兵接收端：native 链回来的 exception sentinel 变成对应的 Zig `HostError`。
- **实现**：`ctx.exceptionIsUncatchable()` 为真给 `error.Interrupted`，否则一律 `error.JSException`；只读标志位，不动 pending exception。
- **所有权 / 错误 / 调用**：无：读两个标志位，不分配、不改 pending exception。返回值只有两种：`ctx.exceptionIsUncatchable()` 时 `error.Interrupted`（保住 VM 预建的不可捕获 InternalError），否则一律 `error.JSException`——**包括 OOM**。函数注释详细论证了为什么不给 OOM 单独的错误类别：一旦到了这道缝，OOM 已经是普通可捕获 JS 异常，扩宽类别会让 `pendingExceptionMatchesError` 不再匹配（重建 Error、丢栈）、promise job 重新入队、module / async-generator 把它当硬错误而不是 rejection；`current_exception_out_of_memory` 这个标志只在嵌入边界（`binding.JSContext.restoreUncaughtOutOfMemory`）读一次。5 个调用方：本文件 `sentinelToHost`（109）、`callNativeAccessorTarget`（1079），以及 `src/exec/vm_native.zig:78`、`src/exec/tailcall_dispatch.zig:579`/4142。

### `sentinelToHost` (`src/exec/builtin_dispatch.zig:108`)

- **签名**：`inline fn sentinelToHost(ctx: *core.JSContext, v: NativeValue) HostError!core.JSValue`。
- **作用**：rooted 路径的接收端：把 sentinel 收成 `HostError`，否则原值返回。
- **实现**：`v.isException()` 则 `nativeHostError(ctx)`。故意不断言 sentinel ⇔ pending：宿主调用方可以带着 pending 进来（qjs `JS_Call` 允许）。
- **所有权 / 错误 / 调用**：不分配、不建根；返回值是被调 native 体刚产出的值，所有权随之转给调用方。错误：哨兵值转成 `HostError`——`nativeHostError` 在 `ctx.exceptionIsUncatchable()` 时给 `error.Interrupted`，否则一律 `error.JSException`（OOM 也被折叠进去，理由见 `nativeHostError` 的长注释）。**它不 assert 哨兵与 pending 的等价关系**：host 调用方可以带着已有的 pending exception 进来（qjs `JS_Call` 允许），函数注释明说了这点。6 个调用方全在本文件 `invokeEntry` 的各 kind 臂（`src/exec/builtin_dispatch.zig:812`、817、821、826、841）与 `invokeLeafFallback`（1246）。

### `hostResultToValue` (`src/exec/builtin_dispatch.zig:114`)

- **签名**：`pub inline fn hostResultToValue(ctx: *core.JSContext, result: HostError!core.JSValue) core.JSValue`。
- **作用**：宿主错误到 JS 值的转换。
- **实现**：`result catch |err| nativeFromHostError(ctx, ctx.global, err)`；thunk 点的 `ctx` 就是被调方 realm，所以它的 global 是 Error 构造器的权威来源。
- **所有权 / 错误 / 调用**：`sentinelToHost` 的反向 thunk。成功路径直接透传值；失败路径把 `HostError` 交给 `nativeFromHostError`，那边**会真建一个 Error 对象并 `ctx.throwValue` 装成 pending exception**（建不出来就退到 realm 预分配的 OOM 值），然后返回哨兵。注释点明 `ctx` 在每个 thunk 站点都是被调方 realm，所以 `ctx.global` 就是 Error 构造器的权威来源。调用方分布在各 `*_ops.zig` 的 NB2 thunk：`src/exec/native_legacy.zig:89`/98/107/115/124/132、`src/exec/function_ops.zig:109`/129/149、`src/exec/array_builtin_ops.zig:404`/469、`src/exec/object_builtin_ops.zig:703`、`src/exec/string_builtin_ops.zig:507`、`src/exec/math_ops.zig:106`，共 6 个文件 14 处。

### `hostErrorToValue` (`src/exec/builtin_dispatch.zig:121`)

- **签名**：`pub inline fn hostErrorToValue(ctx: *core.JSContext, global: ?*core.Object, err: anyerror) core.JSValue`。
- **作用**：宿主错误到 JS 值的转换。
- **实现**：直接转 `nativeFromHostError(ctx, global, err)` 再 `nativeFromBits`。
- **所有权 / 错误 / 调用**：与 `hostResultToValue` 的失败半边等价，但把 `global` 显式传进来——调用点全是「`ctx.global` 为 null，拿不到 Error 构造器」那种情形（`ctx.global orelse return hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry)`）。同样会建 Error 对象并装 pending exception，返回哨兵值，自身无 error set。调用方 16 处跨 7 个引擎文件：`src/exec/object_builtin_ops.zig:687`/698、`src/exec/function_ops.zig:104`/124/144、`src/exec/array_builtin_ops.zig:392`/402/462、`src/exec/string_builtin_ops.zig:426`/435/502、`src/exec/promise_ops.zig:1043`/1087、`src/exec/call.zig:118`/120、`src/exec/math_ops.zig:105`（另有 `src/tests/helpers.zig:901` 一处测试）。

### `embedderErrorToValue` (`src/exec/builtin_dispatch.zig:132`)

- **签名**：`pub noinline fn embedderErrorToValue(ctx: *core.JSContext, err: anyerror) core.JSValue`。
- **作用**：嵌入缝（`zjs.native.managed` thunk）：宿主 Zig error 变成 pending JS 异常。
- **实现**：引擎控制错误（OutOfMemory / ProcessExit / Interrupted / Timeout / StackOverflow / UnhandledPromiseRejection）走 `nativeFromHostError`。其余：已有 pending 则原样返回 sentinel；无 global 同样 `nativeFromHostError`；否则 `embedderErrorInfo` 取构造器名与消息（六个标准名空消息，`InvalidUtf8`→URIError，其它 `Error: <name>`），`createNamedError` + `throwValue`。
- **所有权 / 错误 / 调用**：返回的永远是 exception sentinel。创建失败改走 `nativeFromHostError`。调用方：binding managed thunk。

### `embedderErrorInfo` (`src/exec/builtin_dispatch.zig:149`)

- **签名**：`fn embedderErrorInfo(err: anyerror) struct { name: []const u8, message: []const u8 }`。
- **作用**：把嵌入方的 Zig error 名映射成（构造器名, 消息）。
- **实现**：按 `err` 分支：六个标准 error 名映到同名构造器且消息为空，`URIError`/`InvalidUtf8` 都归 URIError，其余是 `Error` + `@errorName(err)` 作消息。
- **所有权 / 错误 / 调用**：无：纯 switch，返回的 `name` / `message` 都是静态字符串字面量的借用切片（`else` 臂用 `@errorName(err)`，也是静态的），不分配、无 error set。唯一调用方 `embedderErrorToValue`（`src/exec/builtin_dispatch.zig:141`），只在「不是引擎控制错误、且当前没有 pending exception、且拿得到 global」这三条都成立时才走到。

### `vmCallerView` (`src/exec/builtin_dispatch.zig:173`)

- **签名**：`pub inline fn vmCallerView(ctx: *core.JSContext) VmCallerView`。
- **作用**：不建 per-call 环境地取回 VM 调用方视图：host output writer 与调用方 bytecode/frame。
- **实现**：有 active invocation 就从 `machine.currentLevel()` 读（native 自己不压 level）；否则读已发布的 `NativeCallEnvironment`；都没有则三个字段全 null。
- **所有权 / 错误 / 调用**：返回的三个字段全是借用指针（`*std.Io.Writer` / `*const Bytecode` / `*Frame`），生命周期绑在当前 invocation 或已发布的 `NativeCallEnvironment` 上——**不可跨调用保存**。不分配、无 error set；查不到来源时三个字段全给 null（rooted host 调用的正常情形）。三路来源的优先级就是函数体的顺序：活跃 invocation → 已发布的 native environment → 空。调用方 12 处跨 8 个文件：`src/exec/function_ops.zig:105`/125/145、`src/exec/array_builtin_ops.zig:393`/463、`src/exec/string_builtin_ops.zig:427`/503、`src/exec/object_builtin_ops.zig:688`、`src/exec/call.zig:119`、`src/exec/math_ops.zig:106`、`src/binding/native.zig:70`、`src/tests/helpers.zig:904`。

### `CallRealmView.caller` (`src/exec/builtin_dispatch.zig:207`)

- **签名**：`pub fn caller(realm: *core.RealmContext) HostError!CallRealmView`。
- **作用**：用传入 realm 的 `global` 组成原子 `CallRealmView`（C_FUNCTION_DATA / 调用者语义）。
- **实现**：`realm.global` 为空则 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：global 是借用别名，不独立选 realm。

### `CallRealmView.cFunction` (`src/exec/builtin_dispatch.zig:214`)

- **签名**：`pub fn cFunction(object: *core.Object) HostError!CallRealmView`。
- **作用**：从真 `C_FUNCTION` 对象取出其构造 realm。
- **实现**：`class_id != c_function` 或 `nativeFunctionRealm()` 为空则 `InvalidBuiltinRegistry`，否则 `caller(realm)`。
- **所有权 / 错误 / 调用**：对应 qjs `p->u.cfunc.realm`。

### `finalCallableRealmView` (`src/exec/builtin_dispatch.zig:234`)

- **签名**：`pub fn finalCallableRealmView( caller: *core.RealmContext, object: *core.Object, ) HostError!CallRealmView`。
- **作用**：在最终可调用臂上选 realm：真 C_FUNCTION 用其构造 realm，其余用传入 caller。
- **实现**：class_id==c_function 则 `CallRealmView.cFunction`，否则 `CallRealmView.caller`。runtime 必须相同。
- **所有权 / 错误 / 调用**：对应 qjs `js_call_c_function` 里迟到的 `ctx = p->u.cfunc.realm`（quickjs.c:17586）。

### `finalCallEnvironment` (`src/exec/builtin_dispatch.zig:251`)

- **签名**：`fn finalCallEnvironment( ctx: *core.JSContext, global: ?*core.Object, globals: []core.global_slots.Slot, func_obj: ?*core.Object, ) HostError!FinalCallEnvironment`。
- **作用**：在调用方完成预检、选定记录之后解析最终调用载体（对照 quickjs.c:17586 迟到的 `ctx = p->u.cfunc.realm`）。
- **实现**：`func_obj` 为 null（合成记录复用）时原样保留传入的 ctx/global/globals 且 `callable_realm = null`；否则经 `finalCallableRealmView` 换成被调方 realm 与它的 global，legacy globals 切片清空。
- **所有权 / 错误 / 调用**：返回的 `FinalCallEnvironment` 是纯借用视图（realm、global、globals 切片、`callable_realm`），不分配、不建根、不转移所有权。错误只有一种来源——`finalCallableRealmView`（`src/exec/builtin_dispatch.zig:234`）里 `CallRealmView.cFunction` / `.caller` 取不到 realm，或跨 runtime 校验 `view.realm.runtime != caller.runtime` 失败，都是 `error.InvalidBuiltinRegistry`；**这里不会产生 JS 异常**，错误要到更外层的 native 终端才被 `materializeRuntimeError` 变成异常。两个调用方都在本文件：`callInternalRecordDirect`（534）、`callConstructRecordImpl`（1332）——只有这两处。

### `activeNativeEnvironment` (`src/exec/builtin_dispatch.zig:293`)

- **签名**：`pub inline fn activeNativeEnvironment(ctx: *core.JSContext) ?*const NativeCallEnvironment`。
- **作用**：读 `ctx.runtime.active_native_call` 并还原成 `*const NativeCallEnvironment`。
- **实现**：空指针返回 null，否则 `@ptrCast(@alignCast(...))`。
- **所有权 / 错误 / 调用**：指向调用方栈上的环境，只在那次同步调用内有效。

### `nativeCall` (`src/exec/builtin_dispatch.zig:300`)

- **签名**：`pub inline fn nativeCall( ctx: *core.JSContext, this_value: core.JSValue, args: []const core.JSValue, magic: i32, ) ?NativeCall`。
- **作用**：在保持 QJS 风格 typed native 签名的同时，从 `active_native_call` 拼回 exec 环境。
- **实现**：读 `ctx.runtime.active_native_call`；空则 null。否则把 env 字段与 this/args/magic 合成 `NativeCall`。
- **所有权 / 错误 / 调用**：不分配。handler 必须在 `callInternalRecordDirectWithEnvironment` 发布的窗口内调用。

### `callableRealm` (`src/exec/builtin_dispatch.zig:327`)

- **签名**：`pub inline fn callableRealm(call: NativeCall) HostError!CallRealmView`。
- **作用**：取一次可观察调用的原子权威；合成的算法式记录复用没有载体，调用前应先判 `callable_realm == null`。
- **实现**：`call.callable_realm orelse error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：无：`call.callable_realm orelse error.InvalidBuiltinRegistry` 一行，不分配。返回的 `CallRealmView` 里 realm 与 global 都是借用别名。注释点明使用契约——带独立算法/裸 runtime 入口的 native 实现应当**先自己判 `callable_realm == null`** 再调它，不要靠这里的 error 当分支。调用方散在各 `*_ops.zig` 的记录 handler 里（`src/exec/array_builtin_ops.zig:313`/370/442/505、`src/exec/object_builtin_ops.zig:281` 等）；`src/tests/builtins.zig:39` 还有一条源码级断言，要求这些 handler 的源文本里出现 `callableRealm(host_call)`。

### `genericMagicFunction` (`src/exec/builtin_dispatch.zig:331`)

- **签名**：`pub fn genericMagicFunction(comptime implementation: core.host_function.NativeGenericMagicFn) core.host_function.NativeFunctionPtr`。
- **作用**：把 comptime generic+magic 实现收成 `NativeFunctionPtr.generic_magic`。
- **实现**：返回 `.{ .generic_magic = implementation }`。
- **所有权 / 错误 / 调用**：comptime。`internal_entries` 普遍用它。

### `constructorOrFunctionMagic` (`src/exec/builtin_dispatch.zig:335`)

- **签名**：`pub fn constructorOrFunctionMagic(comptime implementation: core.host_function.NativeGenericMagicFn) core.host_function.NativeFunctionPtr`。
- **作用**：把 comptime generic+magic 实现收成 `NativeFunctionPtr.constructor_or_func_magic`（既可 call 也可 construct）。
- **实现**：返回 `.{ .constructor_or_func_magic = implementation }`。
- **所有权 / 错误 / 调用**：comptime。`internal_entries` 里 Object/String 这类既可调用又可构造的条目用它。

### `constructorMagic` (`src/exec/builtin_dispatch.zig:339`)

- **签名**：`pub fn constructorMagic(comptime implementation: core.host_function.NativeGenericMagicFn) core.host_function.NativeFunctionPtr`。
- **作用**：把 comptime generic+magic 实现收成 `NativeFunctionPtr.constructor_magic`（只走 construct）。
- **实现**：返回 `.{ .constructor_magic = implementation }`。
- **所有权 / 错误 / 调用**：comptime。`invokeEntry` 的 `.constructor` 臂要求环境里 `is_constructor` 为真。

### `resolveNativeBacktrace` (`src/exec/builtin_dispatch.zig:347`)

- **签名**：`fn resolveNativeBacktrace(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot`。
- **作用**：native 栈帧的 snapshot 解析器：只提供第 0 帧，标 `is_native`，函数值来自 `NativeBacktraceData`。
- **实现**：`index != 0` 返回 null。名字/文件 atom 为 `null_atom`，行列为 0。
- **所有权 / 错误 / 调用**：`data` 必须指向仍活着的 `NativeBacktraceScope.data`。

### `NativeBacktraceScope.init` (`src/exec/builtin_dispatch.zig:369`)

- **签名**：`pub fn init(ctx: *core.JSContext, func_obj: ?*core.Object) NativeBacktraceScope`。
- **作用**：构造尚未入链的 native 栈帧作用域（函数值先写进 `data`，resolver 在 `push` 才接线）。
- **实现**：`function_value` 取自 `func_obj.value()` 或 undefined。`active=false`。不能在 `init` 里 push：返回值移动后指针会悬空。
- **所有权 / 错误 / 调用**：栈上值。调用方必须再 `push`，并用 `defer deinit`。

### `NativeBacktraceScope.push` (`src/exec/builtin_dispatch.zig:378`)

- **签名**：`pub fn push(self: *NativeBacktraceScope) void`。
- **作用**：把 native 帧链到 `ctx` 的 active backtrace，使随后构造的 Error 能看见这个 C 函数。
- **实现**：断言 `!active`。填 `frame.data`/`resolver=resolveNativeBacktrace`，`pushActiveBacktraceFrame`，`active=true`。对照 qjs 每个 C 函数周围的 `JSStackFrame`。
- **所有权 / 错误 / 调用**：`self` 必须已在最终地址（先 `var scope = init(...)` 再 `scope.push()`）。

### `NativeBacktraceScope.deinit` (`src/exec/builtin_dispatch.zig:388`)

- **签名**：`pub fn deinit(self: *NativeBacktraceScope) void`。
- **作用**：若已 push 则弹出 native 栈帧。
- **实现**：`active` 时 `popActiveBacktraceFrame` 并清标志；重复 deinit 是空操作。
- **所有权 / 错误 / 调用**：与 `push` 成对。

### `preflightCFunctionCall` (`src/exec/builtin_dispatch.zig:399`)

- **签名**：`pub inline fn preflightCFunctionCall( caller_ctx: *core.JSContext, caller_global: ?*core.Object, func_obj: ?*core.Object, formal_length: usize, ) HostError!void`。
- **作用**：在进入 native 体之前做 C_FUNCTION 栈预检（对照 qjs `js_check_stack_overflow`）。
- **实现**：`func_obj` 为空或 `class_id != c_function` 直接返回（C_FUNCTION_DATA 与合成复用不过这道闸），否则转 `preflightCFunctionCallAssumeCFunction`。
- **所有权 / 错误 / 调用**：不分配、不建根。作用是在链接 native 帧、切 realm 之前检查原生栈余量；`func_obj` 为 null 或 class 不是 `c_function` 就静默放行（注释：C_FUNCTION_DATA 与合成记录复用故意不走这道门）。错误只有一种——栈不够时 `throwCFunctionStackOverflow` **先装 pending InternalError（"stack overflow"）再返回 `error.StackOverflow`**，所以这是本文件少数在 preflight 阶段就产生 JS 异常的地方；拿不到 global 时退成 `error.InvalidBuiltinRegistry`。8 个调用方跨 4 个文件：本文件 440/533/1330、`src/exec/call_runtime.zig:304`/958/1860、`src/exec/call.zig:290`、`src/exec/class_init_ops.zig:198`。

### `preflightCFunctionCallAssumeCFunction` (`src/exec/builtin_dispatch.zig:411`)

- **签名**：`pub inline fn preflightCFunctionCallAssumeCFunction( caller_ctx: *core.JSContext, caller_global: ?*core.Object, func_obj: *core.Object, formal_length: usize, ) HostError!void`。
- **作用**：在进入 native 体之前做 C_FUNCTION 栈预检（对照 qjs `js_check_stack_overflow`）。
- **实现**：`formal_length * @sizeOf(JSValue)` 溢出即抛栈溢出；`checkNativeStackOverflow(planned)` 报告越界才 `throwCFunctionStackOverflow`，否则直接返回。`func_obj` 未用——class 已由调用方证明。
- **所有权 / 错误 / 调用**：K1 变体：跳过 class_id 门（调用方已证明是 C_FUNCTION），`func_obj` 直接 `_ =` 丢弃——**参数只为签名对齐而留**。不分配。错误同上：`std.math.mul` 溢出或 `checkNativeStackOverflow` 返回 true 都走 `throwCFunctionStackOverflow`（装 pending InternalError + `error.StackOverflow`）。虽然是 `pub`，树内唯一调用方是 `preflightCFunctionCall`（`src/exec/builtin_dispatch.zig:407`）。

### `preflightInternalRecordCFunction` (`src/exec/builtin_dispatch.zig:430`)

- **签名**：`pub inline fn preflightInternalRecordCFunction( caller_ctx: *core.JSContext, caller_global: ?*core.Object, func_obj: ?*core.Object, native_ref: core.function.NativeBuiltinRef, ) HostError!void`。
- **作用**：在进入 native 体之前做 C_FUNCTION 栈预检（对照 qjs `js_check_stack_overflow`）。
- **实现**：先 `internalBuiltinRecord` 探表，缺记录属于终端自己的普通 dispatch miss，直接返回；命中则按 `record.arity` 走 `preflightCFunctionCall`。
- **所有权 / 错误 / 调用**：先按 `(domain, id)` 探 `rt.internalBuiltinRecord`，**探不到就静默 return**（注释：缺记录仍归 terminal 的普通 dispatch miss 处理），探到就用 `record.arity` 当形参数量转 `preflightCFunctionCall`。不分配、不持有 record（静态表元素的借用指针）。错误同 `preflightCFunctionCall`。3 个调用方：`src/exec/call_runtime.zig:1790`/1832 与 `src/exec/regexp_fastpath.zig:169`，都是「外层 dispatcher 要先建 native 帧再做参数强制转换」的场合。

### `throwCFunctionStackOverflow` (`src/exec/builtin_dispatch.zig:443`)

- **签名**：`noinline fn throwCFunctionStackOverflow( caller_ctx: *core.JSContext, caller_global: ?*core.Object, ) HostError!void`。
- **作用**：C_FUNCTION 预检失败：挂 InternalError「stack overflow」并返回 `error.StackOverflow`。
- **实现**：global 取 `caller_global orelse caller_ctx.global`，都没有则 `InvalidBuiltinRegistry`。`throwInternalErrorMessage(..., "stack overflow")` 的 error 原样上抛；成功后仍 `return error.StackOverflow`。
- **所有权 / 错误 / 调用**：异常挂在 caller realm。`preflightCFunctionCallAssumeCFunction` 在 arity×JSValue 溢出或 `checkNativeStackOverflow` 命中时进来。

### `materializeRuntimeError` (`src/exec/builtin_dispatch.zig:457`)

- **签名**：`pub fn materializeRuntimeError(ctx: *core.JSContext, global: ?*core.Object, err: anyerror) HostError!void`。
- **作用**：在 native 帧仍活着时，把引擎 sentinel 变成 JS Error。
- **实现**：无 global 直接 return。`Interrupted` 且 uncatchable 则保留预建 InternalError。pending 已匹配、或 `runtimeErrorInfo` 认不出这个 error 则跳过。否则 `createSentinelError`；建不出来且是 OOM 时改挂 `preallocated_oom_error` 并 `markExceptionOutOfMemory`，error 照常上抛。建成后若已有 pending 先 `clearException` 再 `throwValue`；`err` 本身是 OutOfMemory 时给异常打上 OOM 标记，供 `nativeHostError` 在无人捕获时还原。
- **所有权 / 错误 / 调用**：消息型 throw helper 已挂好异常时走无分配早退。

### `callInternalRecord` (`src/exec/builtin_dispatch.zig:499`)

- **签名**：`pub fn callInternalRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []core.global_slots.Slot, func_obj: ?*core.Object, this_value: core.JSValue, native_ref: core.function.NativeBuiltinRef, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!?core.JSValue`。
- **作用**：按 `native_ref` 探 `internal_builtins` 表并调用记录；host domain、无效/空洞 id、尚未安装标准全局时返回 null。
- **实现**：`ctx.runtime.internalBuiltinRecord(domain, id)` 命中则转 `callInternalRecordDirect`。
- **所有权 / 错误 / 调用**：返回 `HostError!?core.JSValue`：外层 null 不是失败，而是「这个 `(domain, id)` 在表里没有记录」（host 域、无效/空洞 id、或 runtime 还没装标准全局），调用方据此回退到自己的名字/类级联。探到记录后完全交给 `callInternalRecordDirect`（含 preflight、环境解析、`ValueRootFrame` 建根）。自身不分配、不建根。调用方 20 处跨 9 个文件，都是「按 ref 直接打内建」的场合：`src/exec/call_runtime.zig:824`/1131/1316/1326/1370/1375、`src/exec/date_ops.zig:68`/80/101/121、`src/exec/object_ops.zig:1176`/1308/1427、`src/exec/array_ops.zig:3736`/4343、`src/exec/call.zig:850`、`src/exec/string_ops.zig:1973`、`src/exec/construct.zig:66`、`src/exec/module.zig:1285`。

### `callInternalRecordDirect` (`src/exec/builtin_dispatch.zig:521`)

- **签名**：`pub inline fn callInternalRecordDirect( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []core.global_slots.Slot, func_obj: ?*core.Object, this_value: core.JSValue, record: *const core.NativeEntry, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!core.JSValue`。
- **作用**：跳过表探测、直接调用已解析的记录（快路径 memo 里只会存通过过探测的记录）。
- **实现**：`preflightCFunctionCall(record.arity)` → `finalCallEnvironment` 选 realm → `callInternalRecordDirectWithEnvironment`。
- **所有权 / 错误 / 调用**：不建 GC 根（rooted 路径的根在更内层的 `callTypedInternalRecordDirect` 里建）；`record` 是静态表元素的借用指针，`globals` 切片借用。三步：`preflightCFunctionCall` → `finalCallEnvironment` 解析被调 realm → `callInternalRecordDirectWithEnvironment`。错误：preflight 的 `error.StackOverflow`、环境解析的 `error.InvalidBuiltinRegistry`，以及 native 体经 `sentinelToHost` 折叠出的 `error.JSException` / `error.Interrupted`——后者意味着 pending exception 已经装好了，调用方只需把 error 上抛。5 个调用方跨 4 个文件：`src/exec/vm_call.zig:523`、`src/exec/call.zig:836`、`src/exec/call_runtime.zig:308`/2421、本文件 512。

### `callInternalRecordDirectInRealm` (`src/exec/builtin_dispatch.zig:541`)

- **签名**：`pub inline fn callInternalRecordDirectInRealm( view: CallRealmView, output: ?*std.Io.Writer, func_obj: *core.Object, this_value: core.JSValue, record: *const core.NativeEntry, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!core.JSValue`。
- **作用**：已从函数载荷一并取到记录与 `RealmContext` 的分发器的最终 C 函数终端，之后不再查任何 realm 解析器。
- **实现**：要求 `func_obj.class_id == c_function` 且 `func_obj.nativeFunctionRealm() == view.realm`，否则 `error.InvalidBuiltinRegistry`；随后用该 view 组环境（globals 切片为空）走 `callInternalRecordDirectWithEnvironment`。
- **所有权 / 错误 / 调用**：**不做 preflight**（调用方已经做过），但加了两道一致性门：`func_obj.class_id != c_function` 与 `func_obj.nativeFunctionRealm() != view.realm` 都直接 `error.InvalidBuiltinRegistry`。构造环境时 `globals` 填的是本文件的 `empty_realm_globals[0..]`（长度 0 的静态切片，不分配）。其余错误同 `callInternalRecordDirect`。两个调用方都在 `src/exec/call_runtime.zig`（304 行附近的 306 与 960），都是已经从函数 payload 一次性取到 record+realm 的 dispatcher。

### `callInternalRecordDirectWithEnvironment` (`src/exec/builtin_dispatch.zig:561`)

- **签名**：`inline fn callInternalRecordDirectWithEnvironment( view: FinalCallEnvironment, output: ?*std.Io.Writer, func_obj: ?*core.Object, this_value: core.JSValue, record: *const core.NativeEntry, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!core.JSValue`。
- **作用**：已选好 realm 后的内部记录调用：挂 native 栈帧、发布 environment、invoke。
- **实现**：`NativeBacktraceScope` push/defer pop。把 `NativeCallEnvironment` 写到 `runtime.active_native_call`。`invokeResolvedInternalRecord` 失败则 `materializeRuntimeError` 再把原 error 传出。
- **所有权 / 错误 / 调用**：environment 是栈上对象，只在这次同步调用存活。

### `callRecordFromVmInRealm` (`src/exec/builtin_dispatch.zig:608`)

- **签名**：`pub inline fn callRecordFromVmInRealm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func_obj: *core.Object, record: *const core.NativeEntry, realm: *core.RealmContext, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) NativeBits`。
- **作用**：VM 起源的 native 调用核：一次 `bl` 进 native body，结果以 NativeBits 回寄存器。
- **实现**：按 arity×JSValue 做 native stack preflight。直接推 backtrace frame（函数值用 int-pair 存，避免 store-forwarding）。`method_leaf` 先试 `invokeMethodLeafFast`。`!needs_env` 直接 `invokeEntry`；需要环境则 outline 到 `callRecordWithEnvironment`。异常在此 `nativeFromHostError`。
- **所有权 / 错误 / 调用**：receiver/args 已是 operand window 的 trace 根，不再建 ValueRootFrame。调用方：`vm_native.dispatch` 与本文件的 `callNativeAccessorTarget`。

### `callManagedFromWindow` (`src/exec/builtin_dispatch.zig:662`)

- **签名**：`pub inline fn callManagedFromWindow( rt: *core.JSRuntime, realm: *core.RealmContext, entry: *const core.NativeEntry, func_obj: *core.Object, this_value: core.JSValue, args: []const core.JSValue, ) core.JSValue`。
- **作用**：K0 内联臂：从操作数窗口直接调用「不要 environment」的 managed entry。
- **实现**：在调用方自己的栈上挂一条 `rt.hot.current_backtrace_frame` 的 qjs `sf` 链接（函数值按 int-pair 存），一次 `bl` 调 `entry.managed()(realm, this, args.ptr, argc, entry, func_obj)`，恢复链后把原始 sentinel 交回。
- **所有权 / 错误 / 调用**：`kind == .managed`、`!needs_env`、native 栈预检、stack top 发布这几个 guard 由 handler 负责，这里不做。

### `callGetterFromWindow` (`src/exec/builtin_dispatch.zig:687`)

- **签名**：`pub inline fn callGetterFromWindow( rt: *core.JSRuntime, realm: *core.RealmContext, entry: *const core.NativeEntry, func_obj: *core.Object, receiver: core.JSValue, ) core.JSValue`。
- **作用**：K3 untyped getter 臂：W1 `.native_getter` 命中后的一次 `bl`。
- **实现**：同样推 / 弹 `rt.hot.current_backtrace_frame`，中间调 `entry.getter()(realm, receiver, entry)`，sentinel 原样返回。
- **所有权 / 错误 / 调用**：handler 已守好访问器槽并解出 entry。

### `callMethodManagedFromWindow` (`src/exec/builtin_dispatch.zig:710`)

- **签名**：`pub inline fn callMethodManagedFromWindow( rt: *core.JSRuntime, realm: *core.RealmContext, entry: *const core.NativeEntry, func_obj: *core.Object, self_ptr: *anyopaque, this_value: core.JSValue, args: []const core.JSValue, ) core.JSValue`。
- **作用**：K2 `method_managed` 臂：handler 已用 `nativeReceiverSelf` 解出 `self`，这里只补 backtrace 链再 `bl`。
- **实现**：推 / 弹 backtrace 链，中间调 `entry.methodManaged()(realm, self_ptr, this, args.ptr, argc, entry)`。
- **所有权 / 错误 / 调用**：sentinel 原样返回，由调用方判异常。

### `callRecordWithEnvironment` (`src/exec/builtin_dispatch.zig:732`)

- **签名**：`noinline fn callRecordWithEnvironment( output: ?*std.Io.Writer, realm_global: *core.Object, func_obj: *core.Object, record: *const core.NativeEntry, realm: *core.RealmContext, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) NativeBits`。
- **作用**：需要 `NativeCallEnvironment` 的 VM 记录调用：把环境挂到 `runtime.active_native_call`，再 `invokeEntry`。
- **实现**：组环境（callable realm、output、global、空 globals 切片、func_obj、非 constructor、caller bytecode/frame）。保存/恢复 `active_native_call`。`invokeEntry` 失败走 `nativeFromHostError`，成功 `nativeToBits`。outlined 是为了让 `callRecordFromVmInRealm` 热路径在 `!needs_env` 时不付这套 spill。
- **所有权 / 错误 / 调用**：environment 是栈上对象，只在这次同步调用存活。receiver/args 已是 operand window 的 trace 根。

### `invokeResolvedInternalRecord` (`src/exec/builtin_dispatch.zig:763`)

- **签名**：`inline fn invokeResolvedInternalRecord( ctx: *core.JSContext, this_value: core.JSValue, record: *const core.NativeEntry, args: []const core.JSValue, func_obj: ?*core.Object, ) HostError!core.JSValue`。
- **作用**：按 `NativeEntry.kind` / 叶子签名调用已解析记录。
- **实现**：直接转 `callTypedInternalRecordDirect`（rooted 终端的薄包装）。
- **所有权 / 错误 / 调用**：单行转发给 `callTypedInternalRecordDirect`（`src/exec/builtin_dispatch.zig:774`）——**真正的所有权动作在那里**：它给 `receiver` 和 `args` 建了一帧 `core.runtime.ValueRootFrame`（`receiver` 按值、`args` 按 borrowed slice），`activate` / `defer deactivate` 配对，这是 rooted 路径上 builtin 调用参数成为精确根的唯一地方（源码注释举的例子是 `Set.prototype.add` 在插入中途丢失 collection）。错误同 `invokeEntry`：`error.JSException` / `error.Interrupted` / `error.TypeError`。两个调用方都在本文件（`src/exec/builtin_dispatch.zig:595` 与 1352），且两处都用 `catch |err|` 把 error 再翻译一次。

### `callTypedInternalRecordDirect` (`src/exec/builtin_dispatch.zig:774`)

- **签名**：`noinline fn callTypedInternalRecordDirect( ctx: *core.JSContext, this_value: core.JSValue, record: *const core.NativeEntry, args: []const core.JSValue, func_obj: ?*core.Object, ) HostError!core.JSValue`。
- **作用**：rooted 路径的内部记录调用：把 receiver 与 args 钉成精确根，再 `invokeEntry`。
- **实现**：`ValueRootFrame`：单值根指向局部 `receiver` 副本，slice 根借用 `args`。`activate` / `defer deactivate`。outlined 是为了不把 kind switch 胀进热调用点。VM-window 终端不走这里（operand window 已是 `traceStack` 根）；`Set.prototype.add` 中途丢 collection 是这条根的动机（TGC R1-c）。
- **所有权 / 错误 / 调用**：根只在这次调用窗口存活。`invokeResolvedInternalRecord` 转发到此。

### `invokeEntry` (`src/exec/builtin_dispatch.zig:803`)

- **签名**：`inline fn invokeEntry( ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry, args: []const core.JSValue, func_obj: ?*core.Object, ) HostError!core.JSValue`。
- **作用**：NB2 kind 开关：rooted 终端和 VM-window 终端共用，按 `NativeEntry.kind` 调对应原型。
- **实现**：`.managed`/`.constructor_or_func` 调 `entry.managed()` 再 `sentinelToHost`。`.constructor` 要求环境 `is_constructor`。`.getter`/`.setter` 有 sig 走 typed 快路径，否则调 `entry.getter()` / `entry.setter()` 原型。`.leaf` 先 `invokeLeafFast` 再 fallback。`.method_leaf` 先 `invokeMethodLeafFast`，class_id≠0 的 miss 走 receiver TypeError。`.method_managed` 先 `nativeReceiverSelf`。`.retired` → TypeError。
- **所有权 / 错误 / 调用**：`ctx` 是 callee realm。构造器的 `new_target` 只经 environment 发布。失败已由 managed 原型写成 exception sentinel。

### `nativeReceiverSelf` (`src/exec/builtin_dispatch.zig:850`)

- **签名**：`pub inline fn nativeReceiverSelf(this_value: core.JSValue, entry: *const core.NativeEntry) ?*anyopaque`。
- **作用**：K2 接收者解包：`this` 必须是恰好该 entry class 的对象，取出它的 `self` 指针。
- **实现**：非对象或 `class_id != entry.class_id` 返回 null（外来接收者或已 dispose 实例），否则 `obj.nativeSelfAssumeClass()`。
- **所有权 / 错误 / 调用**：返回借用指针；抛 TypeError 由调用方负责。

### `throwNativeReceiverTypeError` (`src/exec/builtin_dispatch.zig:859`)

- **签名**：`pub noinline fn throwNativeReceiverTypeError(ctx: *core.JSContext, entry: *const core.NativeEntry) HostError!core.JSValue`。
- **作用**：K2/K3 接收者 TypeError：挂「`<Class> object expected`」（已 dispose 的实例读同一句，对齐 qjs `JS_GetOpaque2`）并返回 `error.TypeError`。
- **实现**：无 global → `error.TypeError`。类名从 `NativeType.fromRecord(rt, entry.class_id)` 取，没有则 `"native"`。`bufPrint` 失败退回 `"native object expected"`。`throwTypeErrorMessage` 的 error `@errorCast` 上抛。
- **所有权 / 错误 / 调用**：消息在栈上 128 字节缓冲。`invokeMethodLeafMiss` / `method_managed` / typed getter/setter miss / `nativeReceiverSelfOrThrow`。

### `nativeReceiverSelfOrThrow` (`src/exec/builtin_dispatch.zig:871`)

- **签名**：`pub fn nativeReceiverSelfOrThrow(ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry) ?*anyopaque`。
- **作用**：thunk 侧解包（`zjs.native.Class` 造的访问器 / 构造器 thunk）：失败时把 TypeError 留成 pending 并返回 null，让 thunk 用 sentinel 应答。
- **实现**：`nativeReceiverSelf` 命中直接返回，否则 `throwNativeReceiverTypeError` 并吞掉它的 error 后返回 null。
- **所有权 / 错误 / 调用**：返回的是 `obj.nativeSelfAssumeClass()` 的**借用**裸指针（native 实例的 self），所有权仍归 JS 对象。无 error set：走 thunk 侧协议——失败时用 `throwNativeReceiverTypeError` 把 `"<Class> object expected"` 装成 pending TypeError（该函数内部有 128 字节栈缓冲拼消息，`bufPrint` 溢出退到常量串）并返回 null，由 thunk 自己答哨兵。两个调用方都在 `src/binding/native.zig`（579 与 641，访问器与构造器 thunk），后面紧跟 `orelse return JSValue.exception()`。

### `marshalI32` (`src/exec/builtin_dispatch.zig:879`)

- **签名**：`pub inline fn marshalI32(val: core.JSValue) ?i32`。
- **作用**：FNABI 规范 marshal：只接受已是目标标签的值，不做 ToNumber。
- **实现**：包成单元素数组走 `leafI32Arg`，即与叶子臂完全同一套无强制转换规则。
- **所有权 / 错误 / 调用**：无：把单个值包成一元栈数组转给 `leafI32Arg`，不分配、无 error set，**不做任何强制转换**（FNABI §15.3 的 canonical 策略：只有数学值确是 int32 的 Number 才算命中，`-0.0` 也算 miss）。两个调用方：`src/binding/native.zig:665`（miss 即 `throwTypeErrorSentinel("int32 expected")`）与本文件 `invokeTypedSetterFast`（988，miss 即 `.value_miss`）。

### `marshalF64` (`src/exec/builtin_dispatch.zig:884`)

- **签名**：`pub inline fn marshalF64(val: core.JSValue) ?f64`。
- **作用**：FNABI 规范 marshal：只接受已是目标标签的值，不做 ToNumber。
- **实现**：包成单元素数组走 `leafF64Arg`。
- **所有权 / 错误 / 调用**：无：同 `marshalI32` 的形状，转给 `leafF64Arg`——只接受 Number（int 标签或 double），其余一律 miss，不强制转换。两个调用方：`src/binding/native.zig:661`（`throwTypeErrorSentinel("number expected")`）与本文件 `invokeTypedSetterFast`（983）。

### `throwTypeErrorSentinel` (`src/exec/builtin_dispatch.zig:891`)

- **签名**：`pub fn throwTypeErrorSentinel(ctx: *core.JSContext, message: []const u8) NativeValue`。
- **作用**：在 native thunk 里抛一个带消息的 `TypeError`，并把它折成边界要求的 `NativeValue` 哨兵返回值。
- **实现**：无 global 时直接 `nativeFromHostError(TypeError)`；否则 `throwTypeErrorMessage(ctx, global, message)`，此后有 pending 就返回 sentinel，仍然没有则再走 `nativeFromHostError`。
- **所有权 / 错误 / 调用**：会真建一个 TypeError 对象并装成 pending exception，返回哨兵值；`message` 是调用方给的静态串，不复制所有权。无 error set——失败也只落到哨兵（`throwTypeErrorMessage` 的错误被 `catch {}` 吞掉，随后 `ctx.hasException()` 不成立时再走 `nativeFromHostError` 兜底；`ctx.global` 为 null 时直接走兜底）。5 个调用方全在 `src/binding/native.zig`（382/383 构造器门，661/665/669 三个 setter marshal miss）。

### `invokeNativeMethodLeafFast` (`src/exec/builtin_dispatch.zig:900`)

- **签名**：`inline fn invokeNativeMethodLeafFast(entry: *const core.NativeEntry, this_value: core.JSValue, args: []const core.JSValue) ?core.JSValue`。
- **作用**：K2 typed leaf 臂（native 对象接收者）：class 检查 + `self` 解包 + 参数 marshal + 直接 C 调用 + 装箱。
- **实现**：先 `nativeReceiverSelf`，再按 `entry.sig` 选 SELF_* 原型：self_i32_to_i32 / self_to_i32 / self_i32_to_void / self_to_void / self_to_f64 / self_f64_to_void / self_f64_f64_to_void；接收者 miss、参数标签 miss 或未知 sig 都返回 null。
- **所有权 / 错误 / 调用**：不分配、不建根、无 error set：`nativeReceiverSelf` 借出 self 指针，按 `entry.sig` 选一条七选一的 `SELF_*` 直调臂，结果用 `JSValue.int32` / `numberToValue` 装箱。任何 miss（receiver 类不符、参数 tag 不符、sig 不在表内）一律 `return null`，**不装 pending exception**——抛错是调用方 `invokeMethodLeafMiss` 的事。唯一调用方是 `invokeMethodLeafFast` 的 `else` 臂（`src/exec/builtin_dispatch.zig:1121`）。

### `invokeMethodLeafMiss` (`src/exec/builtin_dispatch.zig:946`)

- **签名**：`noinline fn invokeMethodLeafMiss( ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry, args: []const core.JSValue, func_obj: ?*core.Object, ) HostError!core.JSValue`。
- **作用**：K2 叶子 miss：坏接收者抛 class TypeError；参数标签 miss 走 entry fallback（规范策略下无 fallback 则 TypeError）。
- **实现**：`nativeReceiverSelf == null` → `throwNativeReceiverTypeError`。否则 `invokeLeafFallback`。
- **所有权 / 错误 / 调用**：`invokeEntry` 的 `.method_leaf` 在 `class_id != 0` 且快路径 miss 时进来。

### `invokeTypedGetterFast` (`src/exec/builtin_dispatch.zig:959`)

- **签名**：`pub inline fn invokeTypedGetterFast(entry: *const core.NativeEntry, this_value: core.JSValue) ?core.JSValue`。
- **作用**：K3 typed getter 臂：class 检查 + `self` + 直接 C 调用 + 装箱。
- **实现**：`nativeReceiverSelf` miss 返回 null；否则按 `entry.sig` 走 `self_to_f64` / `self_to_i32`，其他 sig 的 `else` 臂也返回 null。
- **所有权 / 错误 / 调用**：不分配、不建根、无 error set，返回 null 表示 receiver 类不符**或 sig 不在支持集内**——嵌入方经 `zjs.native.Class` 注册了别的 typed accessor sig 时是优雅 miss（与同族 `invokeLeafFast` 一致），不再是 `unreachable` 的 UB/panic。3 个调用方：`src/binding/property_site.zig:177`、`src/exec/tailcall_dispatch.zig:4125`（W1 属性 IC 的内联臂）、本文件 `invokeTypedGetter`（997）。

### `invokeTypedSetterFast` (`src/exec/builtin_dispatch.zig:981`)

- **签名**：`pub inline fn invokeTypedSetterFast(entry: *const core.NativeEntry, this_value: core.JSValue, new_value: core.JSValue) TypedSetterOutcome`。
- **作用**：K3 typed setter 臂，结果用 `TypedSetterOutcome` 表示（stored / receiver_miss / value_miss）。
- **实现**：先解 `self`，失败即 `.receiver_miss`；再按 sig 用 `marshalF64` / `marshalI32` 取值（规范策略不做 ToNumber），取不到即 `.value_miss`；其他 sig 的 `else` 臂也返回 `.receiver_miss`。
- **所有权 / 错误 / 调用**：不分配、无 error set；用三态枚举 `TypedSetterOutcome` 区分 `.stored` / `.receiver_miss` / `.value_miss`，让调用方分别抛两种不同的 TypeError。marshal 走 `marshalF64` / `marshalI32`，不做强制转换。`else` 臂不再是 `unreachable`：支持集外的 sig（只有 `self_f64_to_void` / `self_i32_to_void` 走直呼）报 `.receiver_miss`，由调用方抛类 TypeError，与 `invokeTypedGetterFast` 对称。虽然是 `pub`，树内唯一调用方是下面的 `invokeTypedSetter`（`src/exec/builtin_dispatch.zig:1002`）。

### `invokeTypedGetter` (`src/exec/builtin_dispatch.zig:1002`)

- **签名**：`fn invokeTypedGetter(ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry) HostError!core.JSValue`。
- **作用**：K3 typed getter 的带错误终端：快臂命中就返回值，receiver 类不符就把 TypeError 装成 pending 并返回 `error.TypeError`。
- **实现**：`invokeTypedGetterFast` 命中即返回，否则 `throwNativeReceiverTypeError`。
- **所有权 / 错误 / 调用**：快臂命中就直接返回值（不分配、不建根）；miss 时 `throwNativeReceiverTypeError` 建 TypeError 对象、装 pending exception，并返回 `error.TypeError`——所以这里的 error 与 pending exception 是**同时**产生的，调用方不要再造一个。两个调用方都在本文件：`invokeEntry` 的 `.getter` 臂（`src/exec/builtin_dispatch.zig:820`，条件 `entry.sig != 0`）与 `callNativeAccessorTarget`（1071）。

### `invokeTypedSetter` (`src/exec/builtin_dispatch.zig:1007`)

- **签名**：`fn invokeTypedSetter(ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry, new_value: core.JSValue) HostError!core.JSValue`。
- **作用**：K3 typed setter 的带错误终端：把 `invokeTypedSetterFast` 的三态结果翻成 `HostError!JSValue`（存成功给 undefined，两种 miss 各抛一种 TypeError）。
- **实现**：按 `invokeTypedSetterFast` 的结果分支：`.stored` 返回 undefined，`.receiver_miss` 抛接收者 TypeError，`.value_miss` 抛 `throwTypedSetterValueTypeError`。
- **所有权 / 错误 / 调用**：把三态结果翻成 `HostError!JSValue`：`.stored` → `undefined`，`.receiver_miss` → `throwNativeReceiverTypeError`（"<Class> object expected"），`.value_miss` → `throwTypedSetterValueTypeError`（按 sig 给 "int32 expected" 或 "number expected"）。后两条都是先装 pending TypeError 再返回 `error.TypeError`。不分配值、不建根。两个调用方都在本文件：`invokeEntry` 的 `.setter` 臂（`src/exec/builtin_dispatch.zig:825`）与 `callNativeAccessorTarget`（1074）。

### `throwTypedSetterValueTypeError` (`src/exec/builtin_dispatch.zig:1015`)

- **签名**：`pub noinline fn throwTypedSetterValueTypeError(ctx: *core.JSContext, entry: *const core.NativeEntry) HostError!core.JSValue`。
- **作用**：typed setter 的值 marshal miss：挂 TypeError（i32 签名「int32 expected」，否则「number expected」）并返回 `error.TypeError`。
- **实现**：无 global → `error.TypeError`。`entry.sig == sig_self_i32_to_void` 选消息。`throwTypeErrorMessage` 的 error `@errorCast`。
- **所有权 / 错误 / 调用**：规范 marshal 不做 ToNumber。`invokeTypedSetter` 的 `.value_miss` 臂。

### `tryNativeAccessorCall` (`src/exec/builtin_dispatch.zig:1027`)

- **签名**：`pub fn tryNativeAccessorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, accessor: core.JSValue, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, comptime expected_kind: core.native_entry.Kind, ) ?HostError!core.JSValue`。
- **作用**：K3 直调：accessor 若是 entry 为 `.getter` / `.setter` 的 native 函数，就走 VM native 终端；是别的（字节码 getter、bound function…）就返回 null 让调用方保持原路径。
- **实现**：`nativeAccessorTarget` 先做纯判定，命中再 `callNativeAccessorTarget`。
- **所有权 / 错误 / 调用**：返回类型是 `?HostError!core.JSValue` 的**双层可选**：外层 null = 「这不是 native 访问器，调用方保持原路径」（不是失败），内层 error 才是真失败。自身不分配、不建根。错误全来自 `callNativeAccessorTarget`（typed 臂的 TypeError，或 VM 终端折叠出的 `error.JSException`）。3 个调用方跨 3 个文件：`src/exec/object_ops.zig:3555`、`src/exec/call_runtime.zig:4860`、`src/exec/tailcall_dispatch.zig:4802`。

### `nativeAccessorTarget` (`src/exec/builtin_dispatch.zig:1051`)

- **签名**：`pub inline fn nativeAccessorTarget(accessor: core.JSValue, comptime expected_kind: core.native_entry.Kind) ?NativeAccessorTarget`。
- **作用**：从访问器槽的值解析出 native 访问器目标（函数对象 + entry + realm），是 `tryNativeAccessorCall` 的纯判定半边，便于 handler 在发布 pc / stack top 前先决策。
- **实现**：值必须是对象（属性槽读出的表达式值，只用 tag 判别）且 `class_id == c_function`，`nativeCallTarget()` 拿到 entry/realm，`entry.kind` 还要等于 comptime 的 `expected_kind`，否则 null。
- **所有权 / 错误 / 调用**：纯判定，不分配、无 error set、不发布任何 VM 状态——这正是它从 `tryNativeAccessorCall` 里拆出来的目的（注释：让 handler 在发布 pc / 栈顶之前就能决定）。返回的 `NativeAccessorTarget` 三个字段全是借用指针（函数对象、静态表里的 `NativeEntry`、realm）。用 `objectFromValueTrustedExpression` 而不是通用解包，依据是「accessor 值来自属性槽读，是表达式值，tag 测试足以识别对象」。6 个调用方跨 3 个文件：`src/exec/tailcall_dispatch.zig:4015`/4068/4122/7325、`src/binding/property_site.zig:175`、本文件 1032。

### `callNativeAccessorTarget` (`src/exec/builtin_dispatch.zig:1062`)

- **签名**：`pub fn callNativeAccessorTarget( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: NativeAccessorTarget, receiver: core.JSValue, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, comptime expected_kind: core.native_entry.Kind, ) HostError!core.JSValue`。
- **作用**：调用一个已由 `nativeAccessorTarget` 解析出 `NativeEntry` 的原生 getter / setter，typed 叶子与通用记录两条路径在此分流。
- **实现**：typed 访问器（`entry.sig != 0`）按叶子契约直接走 `invokeTypedGetter` / `invokeTypedSetter`——不预检、不推 backtrace 帧；否则 `callRecordFromVmInRealm`，再把 sentinel 收成 `HostError`。setter 缺参时用 undefined。
- **所有权 / 错误 / 调用**：两条路径的协议不同：`entry.sig != 0`（typed 访问器）走叶契约——**不 preflight、不压 backtrace 帧**，直接 `invokeTypedGetter` / `invokeTypedSetter`；否则走 `callRecordFromVmInRealm`（含栈 preflight 与 qjs `sf` backtrace 链），拿到哨兵后 `nativeIsExc` 断言并 `nativeHostError` 折叠成 `error.JSException` / `error.Interrupted`。自身不分配、不建根（参数来自操作数窗口，已被 invocation 追踪）。5 个调用方：`src/exec/tailcall_dispatch.zig:4018`/4071/4149/7328 与本文件 `tryNativeAccessorCall`（1033）。

### `invokeLeafFastEntry` (`src/exec/builtin_dispatch.zig:1090`)

- **签名**：`pub inline fn invokeLeafFastEntry(entry: *const core.NativeEntry, args: []const core.JSValue) ?core.JSValue`。
- **作用**：VM 侧的 K1 leaf 入口（`vm_native.dispatch` 与 tailcall 内联臂）。
- **实现**：直接转 `invokeLeafFast`。
- **所有权 / 错误 / 调用**：无：单行转发 `invokeLeafFast`，不分配、无 error set，null 即 miss（调用方回退到带环境的慢路径）。存在的意义是给 VM 侧一个 `pub` 入口而不暴露内部的 `invokeLeafFast`。3 个调用方：`src/exec/vm_native.zig:55` 与 `src/exec/tailcall_dispatch.zig:2123`/2425（两处内联叶臂）。

### `invokeMethodLeafFastEntry` (`src/exec/builtin_dispatch.zig:1098`)

- **签名**：`pub noinline fn invokeMethodLeafFastEntry(ctx: *core.JSContext, entry: *const core.NativeEntry, this_value: core.JSValue, args: []const core.JSValue) ?core.JSValue`。
- **作用**：VM 侧 K2 `prim_self` 入口（`op_call_method` 内联臂）：`this` 是 operand-window 接收者。
- **实现**：直接 `invokeMethodLeafFast`。outlined 是为了不把字符串标签检查和 boxing 塞进 `op_call_method` handler（handler 体积对 island tail 是负载）。
- **所有权 / 错误 / 调用**：miss 返回 null，调用方走 fallback。调用方：`tailcall_dispatch` 的 `op_call_method` 内联臂。

### `invokeMethodLeafFast` (`src/exec/builtin_dispatch.zig:1108`)

- **签名**：`inline fn invokeMethodLeafFast(ctx: *core.JSContext, entry: *const core.NativeEntry, this_value: core.JSValue, args: []const core.JSValue) ?core.JSValue`。
- **作用**：K2 `prim_self` 臂：字符串接收者 + i32 下标的直调；其余签名交给 `invokeNativeMethodLeafFast`。
- **实现**：`sig_string_i32_to_i32` / `sig_string_i32_to_string` 用 `leafStringReceiver` 取扁平串、`leafI32Arg` 取下标，结果 <0 视为 miss（后者再 `leafCodeUnitString` 装成单码元字符串）；默认分支转 `invokeNativeMethodLeafFast`。
- **所有权 / 错误 / 调用**：字符串臂不分配（receiver 是既有 String 的借用 body）；结果字符串由 `leafCodeUnitString` 给出，latin1 单元命中 runtime 的单码元串表、不分配，BMP 才真建。不建根、无 error set：任何 miss（非字符串 / 未线性化的 rope / Symbol receiver / 非 int32 下标 / 目标返回负数）一律 null，由调用方退到 fallback 走完整 ToString / ToIntegerOrInfinity 语义。3 个调用点全在本文件：`callRecordFromVmInRealm`（`src/exec/builtin_dispatch.zig:642`）、`invokeEntry` 的 `.method_leaf` 臂（835）、`invokeMethodLeafFastEntry`（1093）。

### `leafStringReceiver` (`src/exec/builtin_dispatch.zig:1136`)

- **签名**：`inline fn leafStringReceiver(this_value: core.JSValue) ?*const core.string.String`。
- **作用**：`prim_self` 的接收者解包：扁平字符串，或已被先前读操作线性化的 rope 的扁平体。
- **实现**：tag 为 string 取 `asStringBodyRaw`，string_rope 取 `ropeBody().flatString()`，其余（含共享同一布局的 Symbol）返回 null，让 fallback 走完整 ToString。
- **所有权 / 错误 / 调用**：返回**借用**的 `*const core.string.String` body，不加引用、不分配、无 error set。三条语义都在注释里：Symbol 共享 body 布局但必须 miss（ToString 对它抛错）；未线性化的 rope 也 miss，好让 fallback 像 qjs `js_linearize_string_rope` 那样线性化一次；已线性化的 rope 用节点里缓存的 flat body。两个调用点都在 `invokeMethodLeafFast`（`src/exec/builtin_dispatch.zig:1106` 与 1114）。

### `leafCodeUnitString` (`src/exec/builtin_dispatch.zig:1154`)

- **签名**：`inline fn leafCodeUnitString(rt: *core.JSRuntime, unit: u16) ?core.JSValue`。
- **作用**：造 charAt / at 的单码元结果字符串。
- **实现**：`< 0x100` 走运行时单字节字符串表 `rt.singleByteString`（首次之后不再分配），否则 `String.createUtf16`；分配失败返回 null 当作 miss，由 fallback 重做并报错（函数头注释已写明这是有意的取舍）。
- **所有权 / 错误 / 调用**：`unit < 0x100` 时从 runtime 的单码元串表取（`singleByteString`，首次之后**零分配**），否则 `String.createUtf16` 真建一个一码元字符串。返回的值随后立刻被装箱返回给 VM，不建根。无 error set：**分配失败被 `catch return null` 变成一次 miss**，由 fallback（legacy `charAt`/`at` 函数体）立刻重做同一次分配并走正常错误通道。这是本文件里唯一把 OOM 降级成 miss 的地方，函数头注释已写明为有意：本臂与它的 VM 调用方 `invokeMethodLeafFastEntry` 都是 `?JSValue`，没有错误通道；代价是「fallback 重分配时内存压力已过去」的那次 OOM 只表现为多跑一遍慢路径。唯一调用方 `invokeMethodLeafFast` 的 `sig_string_i32_to_string` 臂（`src/exec/builtin_dispatch.zig:1118`）。

### `invokeLeafFast` (`src/exec/builtin_dispatch.zig:1169`)

- **签名**：`inline fn invokeLeafFast(entry: *const core.NativeEntry, args: []const core.JSValue) ?core.JSValue`。
- **作用**：K1 leaf 臂：按 `entry.sig` 做标签检查 + 直接 C 调用 + 装箱，不建 environment。
- **实现**：按 `entry.sig` 覆盖 f64→f64、(f64,f64)→f64、void→void、i32→i32、(i32,i32)→i32、f64→void、bool→bool、state+f64→void、state+i32→i32；两条返回 f64 的 sig（`f64_to_f64` / `f64_f64_to_f64`）用宽松的 `primitiveF64Arg`（bool/null/undefined 也给值），而 `f64_to_void` / `state_f64_to_void` 两条用严格的 `leafF64Arg`（只收 Number）；整数 sig 用 `leafI32Arg`，`bool_to_bool` 用 `args[0].asBool()`；任一 miss 或未知 sig 返回 null。
- **所有权 / 错误 / 调用**：不分配、不建根、无 error set：按 `entry.sig` 选九选一的直调臂（f64/i32/bool/void 组合，外加两条带 `entry.state.?` 的 state 臂），结果用 `numberToValue` / `int32` / `boolean` 装箱。任何 tag miss 或未登记 sig 一律 null——注释写明这是 FNABI §15.3/§15.6 的 canonical 策略：缺参数即 `undefined`，因此也算 miss。⚠️ 两条 state 臂用 `entry.state.?` 解包，登记了 state sig 却没填 state 的记录会在这里 panic。两个调用点都在本文件：`invokeEntry` 的 `.leaf` 臂（`src/exec/builtin_dispatch.zig:829`）与 `invokeLeafFastEntry`（1085）。

### `leafI32Arg` (`src/exec/builtin_dispatch.zig:1228`)

- **签名**：`inline fn leafI32Arg(args: []const core.JSValue, index: usize) ?i32`。
- **作用**：规范 i32 marshal（FNABI §15.3）：只接受数学值确为 int32 的 Number。
- **实现**：缺参即 miss；int 标签直接取；double 必须是整数、落在 int32 范围内且不是 -0。
- **所有权 / 错误 / 调用**：无：读一个操作数，不分配、无 error set。canonical i32 marshal 的四条拒绝规则都在函数体里——下标越界（含缺参数）、非整 double、超出 int32 范围、以及 `-0.0`（显式判 `signbit`）。8 个调用点全在本文件的叶臂：`marshalI32`（881）、`invokeNativeMethodLeafFast`（905/914）、`invokeMethodLeafFast`（1107/1115）、`invokeLeafFast`（1177/1182/1183）。

### `leafF64Arg` (`src/exec/builtin_dispatch.zig:1243`)

- **签名**：`inline fn leafF64Arg(args: []const core.JSValue, index: usize) ?f64`。
- **作用**：规范 f64 marshal（FNABI §15.3）：只接受 Number。
- **实现**：缺参即 miss；int 标签转 f64，否则 `asFloat64()`（非 Number 返回 null）。
- **所有权 / 错误 / 调用**：无：不分配、无 error set。比 `primitiveF64Arg` 严格——只接受 Number（int 标签转 float 或 double），缺参数/其它 tag 一律 null，不把 `undefined` 当 NaN。6 个调用点全在本文件：`marshalF64`（886）、`invokeNativeMethodLeafFast`（929/935/936）、`invokeLeafFast`（1188/1200）。

### `invokeLeafFallback` (`src/exec/builtin_dispatch.zig:1250`)

- **签名**：`noinline fn invokeLeafFallback( ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry, args: []const core.JSValue, func_obj: ?*core.Object, ) HostError!core.JSValue`。
- **作用**：叶子快路径 miss 后的冷路径：调 entry 的 managed fallback；没有 fallback 则 TypeError（FNABI 规范 marshal：缺参是 undefined，因此是 miss）。
- **实现**：`entry.fallback orelse return error.TypeError`，再 `sentinelToHost(fallback(ctx, this, args.ptr, argc, entry, func_obj))`。
- **所有权 / 错误 / 调用**：`.leaf` / `.method_leaf`（`class_id==0`）miss 与 `invokeMethodLeafMiss` 的参数 miss。fallback 已把异常写成 sentinel。

### `primitiveF64Arg` (`src/exec/builtin_dispatch.zig:1271`)

- **签名**：`inline fn primitiveF64Arg(args: []const core.JSValue, index: usize) ?f64`。
- **作用**：数值 cproto 的参数取值，对标 qjs 的 `JS_ToFloat64` 原始类型快路径；只有 `sig_f64_to_f64` / `sig_f64_f64_to_f64` 两条 K1 臂用它，这是 FNABI §15.3 「任意 JS Number，别的都不收」之外唯一的宽松点（函数头注释与 `zjs.native.leaf` 的文档已同步写明）。
- **实现**：缺参当 NaN；int/double 直接取；bool→1/0，null→0，undefined→NaN；字符串、对象、BigInt、Symbol 一律 miss，交给记录的冷 fallback 做完整可观察 ToNumber。
- **所有权 / 错误 / 调用**：无：不分配、无 error set。与 `leafF64Arg` 的关键差别是它复刻 qjs 的 `JS_ToFloat64` 原始值快路径——**缺参数与 `undefined` 都给 NaN**，bool 给 1/0，null 给 0；字符串 / 对象 / BigInt / Symbol 故意 miss（注释：完整可观察的 ToNumber 语义归记录的冷 fallback）。3 个调用点都在 `invokeLeafFast` 的两条 f64 臂（`src/exec/builtin_dispatch.zig:1161`、1166、1167）。

### `callConstructRecord` (`src/exec/builtin_dispatch.zig:1296`)

- **签名**：`pub fn callConstructRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []core.global_slots.Slot, func_obj: ?*core.Object, native_ref: core.function.NativeBuiltinRef, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!?core.JSValue`。
- **作用**：construct（`new X()`）路径的记录调用：环境标 `is_constructor`，把解析好的实例原型当 `new_target` 发布；id 不走表则返回 null 让调用方回退到名字 / class 级联。
- **实现**：转 `callConstructRecordImpl(true, ...)`，即自己做预检并推 native 帧。
- **所有权 / 错误 / 调用**：`push_native_frame = true` 的转发：会自己 preflight 并压一层 `NativeBacktraceScope`。返回值外层 null 表示 miss（id 无记录，或记录不是 construct-capable——注释点明这是为了不让 wrapper-primitive 的 call 记录被误当构造器跑），调用方回退到构造级联。`prototype` 作为 `new_target` 解析出的实例 `[[Prototype]]` 借用地穿进环境。错误在 `callConstructRecordImpl` 末尾**先 `materializeRuntimeError` 建好 Error 并装 pending，再把 err 原样返回**，所以调用方拿到 error 时异常已经在位。调用方：`src/exec/string_ops.zig:232`/999、`src/exec/class_init_ops.zig:124` 等。

### `callConstructRecordInNativeScope` (`src/exec/builtin_dispatch.zig:1314`)

- **签名**：`pub fn callConstructRecordInNativeScope( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []core.global_slots.Slot, func_obj: ?*core.Object, native_ref: core.function.NativeBuiltinRef, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!?core.JSValue`。
- **作用**：同 `callConstructRecord`，但调用方已持有覆盖参数强制转换的 `NativeBacktraceScope`。
- **实现**：转 `callConstructRecordImpl(false, ...)`，不再推第二个 native 帧，也不重复预检。
- **所有权 / 错误 / 调用**：`push_native_frame = false` 的转发：**不 preflight、不压 backtrace 帧**，因为调用方已经持有一个覆盖其可观察参数强制转换的 `NativeBacktraceScope`，重复压会造出两层 native 帧。其余语义（miss 的 null、`prototype` 借用、错误先 materialize 再上抛）与 `callConstructRecord` 一致。3 个调用方：`src/exec/regexp_fastpath.zig:44`、`src/exec/call_runtime.zig:1818`（String 构造）与 1916（Date 构造）。

### `callConstructRecordImpl` (`src/exec/builtin_dispatch.zig:1329`)

- **签名**：`fn callConstructRecordImpl( comptime push_native_frame: bool, ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []core.global_slots.Slot, func_obj: ?*core.Object, native_ref: core.function.NativeBuiltinRef, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!?core.JSValue`。
- **作用**：`new` 一个由 native 记录实现的内建构造器（`Date` / `RegExp` / `String` 这类 `JS_CFUNC_constructor` 对应物）的公共实现体；`push_native_frame` 这个 comptime 参数区分「从 VM 窗口进来、帧已就绪」与「从宿主进来、需要自己压 backtrace 帧」两个调用点。
- **实现**：探表取记录，缺记录或 `!record.isConstructor()` 都返回 null（让调用方走 construct 级联）；`push_native_frame` 时先 `preflightCFunctionCall` 再 push `NativeBacktraceScope`。`finalCallEnvironment` 选 realm 后，把 `is_constructor = true`、`new_target = prototype` 的环境写进 `active_native_call`，再 `invokeResolvedInternalRecord`；失败先 `materializeRuntimeError` 再把原 error 传出。
- **所有权 / 错误 / 调用**：两个公开入口的共同实现，`push_native_frame` 是 comptime 参数所以两份代码各自特化。所有权：`native_env` 是**栈上**的 `NativeCallEnvironment`，发布进 `runtime.active_native_call` 后用 `defer` 恢复前一个（可重入的保存/恢复协议），`is_constructor = true` 与 `new_target = prototype` 就是构造语义的全部载体；`record` 是静态表借用指针；根由更内层的 `invokeResolvedInternalRecord` → `callTypedInternalRecordDirect` 建。错误：miss 返回 null；其余在末尾 `catch |err| { try materializeRuntimeError(view.ctx, view.global, err); return err; }`——**这是本文件少数在返回前就把 Zig error 变成 pending JS 异常的地方**，注意 `materializeRuntimeError` 自身失败（OOM 建不出 Error）会经 `try` 把新的 error 顶掉原来的。两个调用方就是上面两个公开入口（`src/exec/builtin_dispatch.zig:1289` 与 1307）。

### `isConstructRecordRef` (`src/exec/builtin_dispatch.zig:1383`)

- **签名**：`pub fn isConstructRecordRef(rt: *const core.JSRuntime, native_ref: core.function.NativeBuiltinRef) bool`。
- **作用**：判断该 native id 是否解析到 construct-capable 记录，让构造器判定按 id 而不是按解析出的名字识别内建构造器。
- **实现**：探表，miss 返回 false，否则 `record.isConstructor()`。
- **所有权 / 错误 / 调用**：无：探 `rt.internalBuiltinRecord` 再读 `record.isConstructor()`，不分配、无 error set，探不到返回 false。`rt` 收的是 `*const core.JSRuntime`（本文件少见的 const runtime 形参）。两个调用方：`src/exec/call_runtime.zig:4586` 与 `src/exec/reflect_ops.zig:230`，都在构造器合法性判定里——按 native id 而不是解析出的名字认构造器，所以改了 `name` 的内建构造器仍然合法。

### `callerBytecode` (`src/exec/builtin_dispatch.zig:1389`)

- **签名**：`pub fn callerBytecode(call: NativeCall) ?*const Bytecode`。
- **作用**：从 `NativeCall` 取回 VM 调用方的字节码函数。
- **实现**：返回 `call.caller_function`。
- **所有权 / 错误 / 调用**：无：读 `call.caller_function` 字段，不分配、无 error set。返回的是**借用**的 `*const Bytecode`，只在本次 native 调用期间有效。30 个调用点分布在 18 个 `*_ops.zig`：`src/exec/object_builtin_ops.zig:277`、`src/exec/string_builtin_ops.zig:629`/674、`src/exec/date_ops.zig:485`、`src/exec/number_ops.zig:108`、`src/exec/primitive_ops.zig:142`/180/190/199、`src/exec/promise_builtin_ops.zig:102`/125/158 等，取来都是为了往下传给需要 caller 上下文的 VM 调用。

### `callerFrame` (`src/exec/builtin_dispatch.zig:1394`)

- **签名**：`pub fn callerFrame(call: NativeCall) ?*Frame`。
- **作用**：从 `NativeCall` 取回 VM 调用方的帧。
- **实现**：返回 `call.caller_frame`。
- **所有权 / 错误 / 调用**：无：读 `call.caller_frame` 字段，不分配、无 error set；返回借用的 `*Frame`，同样只在本次调用期间有效（帧在 VM 栈上）。同样 30 个调用点、18 个文件，与 `callerBytecode` 逐处成对出现：`src/exec/function_ops.zig:173`/342/362、`src/exec/array_builtin_ops.zig:354`/379/513、`src/exec/buffer_ops.zig:270`、`src/exec/object_builtin_ops.zig:278` 等。

### `callerResultIsDropped` (`src/exec/builtin_dispatch.zig:1403`)

- **签名**：`pub fn callerResultIsDropped(caller_function: ?*const Bytecode, caller_frame: ?*Frame) bool`。
- **作用**：判断调用方返回后要执行的指令是不是 `drop`（结果被丢弃），让 native 域走无结果的变更快路径。
- **实现**：caller bytecode / frame 缺一返回 false；否则看 `frame.pc` 在字节码范围内且该处字节等于 `bytecode.opcode.op.drop`。对齐 `vm_call.zig` 的 `preparedCallResultIsDropped`。
- **所有权 / 错误 / 调用**：无：只读 caller 帧的 `pc` 处字节码并与 `op.drop` 比较，不分配、无 error set；两个参数任一为 null 即 false，`pc` 越界也 false。存在的理由写在注释里——让各 native 域不必 import `src/bytecode.zig` 就能拿到这个 opcode 判定，语义与 `vm_call.zig` 的 `preparedCallResultIsDropped` 一致。唯一调用方 `src/exec/collection_ops.zig:1658`（`Map.prototype.set` / `Set.prototype.add` 在语句位置走免结果的变更快路径）。


## `src/exec/builtin_glue.zig` — 跨 domain 胶水

Number/BigInt 作函数调用、parseInt/parseFloat、DataView 参数、WeakRef/FinalizationRegistry、Symbol.for/keyFor、集合构造填充。Math/URI/JSON 不在这里。

`internal_entries` 是 `.weak_ref` domain（deref / register / unregister）。Array/Buffer 记录转发到 `array_ops`。


### `numberFunctionCall` (`src/exec/builtin_glue.zig:54`)

- **签名**：`pub fn numberFunctionCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`Number(x)` 被当普通函数调用时的转换体。
- **实现**：无参返回 `+0`；BigInt 直接 `bigIntToNumber`；否则 `toPrimitiveForNumber` 后（结果仍是 BigInt 再转一次）走 `toNumberValue`。
- **所有权 / 错误 / 调用**：不分配持久对象、不建根（`args` 来自 VM 操作数窗口，已被 invocation 追踪）。错误：`toPrimitiveForNumber` 会调用用户的 `valueOf` / `@@toPrimitive`，所以 `error.JSException` 可以从那里冒上来；另有 `error.TypeError` 与分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方都在 `src/exec/call_runtime.zig`（1120 走 `Number(x)` 调用形态，2278 走 `new Number(x)` 先取原始值）。

### `bigIntFunctionCall` (`src/exec/builtin_glue.zig:67`)

- **签名**：`pub fn bigIntFunctionCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`BigInt(x)` 被当函数调用时的转换体（对照 qjs `js_bigint_constructor`）。
- **实现**：缺参用 undefined（ToBigInt(undefined) 要抛）。`toPrimitiveForNumber` 后：int32 走 `createBigIntI128`，f64 走 `integerNumberToBigIntValue`，undefined/null/Symbol 抛同一句 TypeError，其余 `toBigIntValue` + `createBigIntValue`。对照 quickjs.c:56232,56223。
- **所有权 / 错误 / 调用**：⚠️ 这里有**真的本地拥有资源**：`var bigint = try value_ops.toBigIntValue(...); defer bigint.deinit();`——中间的大整数临时量由本函数持有并在返回前释放，`createBigIntValue` 只是把它拷成 JS 值。除此之外不建根。错误：`toPrimitiveForNumber` 可能跑用户代码（`error.JSException`）；undefined / null / Symbol 走的是 `throwTypeErrorMessage("cannot convert to BigInt")`——**这一条是当场装 pending TypeError 再返回它的结果值**，与其余靠上抛的错误不同。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/call_runtime.zig:1117`。

### `bigIntAsN` (`src/exec/builtin_glue.zig:91`)

- **签名**：`pub fn bigIntAsN( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, unsigned: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`BigInt.asIntN` / `asUintN` 的共用体，`unsigned` 选其一。
- **实现**：第一个参数经 ToPrimitive→ToNumber 取 bits：NaN 当 0，非有限 / 负数 / 超过 2^53-1 抛 RangeError，BigInt 或 Symbol 抛 TypeError；第二个参数经 `toBigIntFromPrimitive` 后交给 `value_ops.asN`。`caller_function` / `caller_frame` 未用。
- **所有权 / 错误 / 调用**：`caller_function` / `caller_frame` 两个形参被 `_ =` 丢弃，只为与域内其它记录签名对齐。不分配持久对象、不建根。错误集较宽：`error.TypeError`（bits 参数是 BigInt 或 Symbol）、`error.RangeError`（bits 非有限 / 为负 / 超过 2^53-1）、`toPrimitiveForNumber` 冒上来的 `error.JSException`；NaN 按 0 处理而不是报错。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方都在 `src/exec/primitive_ops.zig`（174 `BigInt.asIntN`、184 `BigInt.asUintN`，靠 `unsigned` 参数区分）。

### `toBigIntFromPrimitive` (`src/exec/builtin_glue.zig:125`)

- **签名**：`pub fn toBigIntFromPrimitive(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：把已经是原始值的输入转成 BigInt（`BigInt.asIntN` / `asUintN` 的第二参用）。
- **实现**：BigInt 原样返回；bool 走 `createBigIntI128(0/1)`；字符串走 `toBigIntValue` + `createBigIntValue`；其余（含 Number、undefined、null、Symbol）一律 `error.TypeError`。
- **所有权 / 错误 / 调用**：BigInt 入参原样返回（借用）；bool 走 `createBigIntI128` 新建；字符串分支同样有 `var bigint = ...; defer bigint.deinit();` 的本地拥有临时量。不建根。错误：其它一切类型一律 `error.TypeError`（**不跑用户代码**，因为入参已经是原始值），加上分配失败与字符串解析失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 虽然是 `pub`，树内唯一调用方是本文件的 `bigIntAsN`（`src/exec/builtin_glue.zig:119`）。

### `globalIsNaNOrFinite` (`src/exec/builtin_glue.zig:136`)

- **签名**：`pub fn globalIsNaNOrFinite( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, is_nan: bool, ) !core.JSValue`。
- **作用**：全局 `isNaN` / `isFinite` 的共用体（`is_nan` 选其一）。
- **实现**：接收者是 Number 构造器时走 `Number.isNaN` / `Number.isFinite` 的严格语义（不转换，非 Number 一律 false）。否则 ToPrimitive（BigInt / Symbol 抛 TypeError）→ ToNumber 再判。
- **所有权 / 错误 / 调用**：不分配、不建根。两条路径的语义差别是关键：receiver 的构造器名是 `"Number"` 时走 `Number.isNaN` / `Number.isFinite` 的**无强制转换**语义（非 Number 直接 false），否则走全局 `isNaN` / `isFinite` 的 ToNumber 语义。后者的 `toPrimitiveForNumber` 会跑用户代码。错误：`error.TypeError`（原始值是 Symbol 或 BigInt）+ `error.JSException` + 分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 4 个调用方：`src/exec/number_ops.zig:124`/128（记录分发）与 `src/exec/call_runtime.zig:1146`/1147（名字级联兜底）。

### `toNumberLikeArgument` (`src/exec/builtin_glue.zig:160`)

- **签名**：`pub fn toNumberLikeArgument( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：把一个参数按 `ToNumber` 归一成 Number 值（BigInt 抛 TypeError），供 `String.prototype` 里那批带数值参数的方法（`string_ops.stringNumericArgsMethod` 统一分发的 `charAt` / `slice` / `substring` / `substr` / `repeat` …，以及 `charCodeAt` 的下标）在整数快路径不命中时做那次可观察的强制转换。
- **实现**：三步：`toPrimitiveForNumber(ctx, output, global, value)` 先走 `ToPrimitive`（hint number，可能回调用户的 `valueOf` / `@@toPrimitive`）；结果是 BigInt 就 `error.TypeError`（注意与 `globalIsNaN` 那条路径不同，这里**不**拒绝 Symbol，Symbol 会在 `toNumberValue` 里报错）；最后 `value_ops.toNumberValue` 后经 `numberValue` / `numberToValue` 归一成规范的 Number 表示，取不到数值时落 NaN。
- **所有权 / 错误 / 调用**：不分配、不建根；非数字结果一律归一成 NaN（`numberValue(...) orelse nan`）。错误：`error.TypeError`（原始值是 BigInt）+ `toPrimitiveForNumber` 跑用户 `valueOf` 时冒出的 `error.JSException`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 3 个调用方跨两个文件：`src/exec/string_builtin_ops.zig:568`（用 `catch |err| return @errorCast(err)` 收窄错误集）、`src/exec/string_ops.zig:3826`，以及 `string_ops.zig:100` 的 `const` 别名。

### `globalParseInt` (`src/exec/builtin_glue.zig:172`)

- **签名**：`pub fn globalParseInt( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：全局 `parseInt` 的记录体。
- **实现**：第一参非字符串时走 `toStringForAnnexB`。radix 参数只在是对象 / Symbol / BigInt 时才做 ToPrimitive→ToNumber，否则原样传下去。最后 `core.number.parseIntValue`。
- **所有权 / 错误 / 调用**：不分配持久对象、不建根；`caller_function` / `caller_frame` 真的被用上了——转给 `toStringForAnnexB`，让字符串化过程能复用调用方的内联缓存提示。错误：`toStringForAnnexB` 与 radix 强制转换都可能跑用户代码（`error.JSException`）；radix 参数只有在是对象 / Symbol / BigInt 时才走完整 ToPrimitive，否则原样传给 `parseIntValue`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方：`src/exec/number_ops.zig:112`（记录分发）与 `src/exec/call_runtime.zig:1144`（名字级联）。

### `globalParseFloat` (`src/exec/builtin_glue.zig:196`)

- **签名**：`pub fn globalParseFloat( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：全局 `parseFloat` 的记录体。
- **实现**：第一参非字符串时走 `toStringForAnnexB`，再 `core.number.parseFloatValue`。
- **所有权 / 错误 / 调用**：与 `globalParseInt` 同形但没有 radix 分支：入参已是字符串就直接用，否则 `toStringForAnnexB`（会跑用户 `toString`，可冒 `error.JSException`），再 `core.number.parseFloatValue`。不分配持久对象、不建根。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方：`src/exec/number_ops.zig:118` 与 `src/exec/call_runtime.zig:1145`。

### `arrayNativeRecord` (`src/exec/builtin_glue.zig:223`)

- **签名**：`pub fn arrayNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: ?*core.Object, id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`.array` domain 的记录分发胶水：Array 的静态方法在此，其余转给 `array_ops` 的原型方法枢纽。
- **实现**：按 `id` 分支：`isArray` 就地判定；`from` / `fromAsync` / `of` 需要已物化的函数对象（为 null 则 TypeError）；其余转 `array_ops.arrayPrototypeNativeRecord`。push/pop/splice 有各自的记录函数，不走这里。调用方的 bytecode/frame 一路转发，保住内联缓存提示。
- **所有权 / 错误 / 调用**：纯转发 hub，自身不分配、不建根；`caller_function` / `caller_frame` 原样往下传（注释：让表路径保住内联缓存提示）。返回 `!?core.JSValue` 的 null 表示 id 不归本域，调用方继续它的兜底。错误：三个 Array 静态方法在 `function_object == null` 时 `error.TypeError`（注释称之为「corrupt null 到达 hub 的 TypeError」），其余全来自被转发的 `array_ops.*`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/array_builtin_ops.zig:345`。注意 push/pop 已经有专用记录函数，**不走这条 hub**。

### `bufferNativeRecord` (`src/exec/builtin_glue.zig:243`)

- **签名**：`pub fn bufferNativeRecord( ctx: *core.JSContext, receiver: core.JSValue, id: u32, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：ArrayBuffer / DataView / TypedArray 记录或构造参数。
- **实现**：依次匹配：`isView` 静态；ArrayBuffer / SharedArrayBuffer / DataView / TypedArray 的 accessor id（各自转对应 accessor 体）；`arrayBufferPrototypeNativeRecord`；DataView 的 get / set 族（没有 global 时直接走 `core.typed_array` 版本，TypeError / RangeError 原样上抛）。全不匹配返回 null。
- **所有权 / 错误 / 调用**：长长的 id 查表链，自身不分配、不建根；返回 null 表示这批 id 没有对应臂（`src/exec/buffer_ops.zig:190` 的注释明确依赖这一点）。值得注意的是 DataView get/set 两段各有一个 `ctx.global orelse` 降级分支：拿不到 global 时绕过 `dataViewGetCall` / `dataViewSetCall` 直接调 `core.typed_array.dataViewGet` / `dataViewSet`，代价是丢掉参数的 ToIndex 强制转换。错误：`error.TypeError` / `error.RangeError` 被显式 `switch` 原样透传（其余 `else => err`）。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/buffer_ops.zig:223`。

### `dataViewConstructorArgs` (`src/exec/builtin_glue.zig:304`)

- **签名**：`pub fn dataViewConstructorArgs( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !DataViewConstructorArgs`。
- **作用**：解析并校验 `new DataView(buffer, byteOffset, length)` 的参数。
- **实现**：四步：`args.len < 1` 即 `error.TypeError`；`core.typed_array.dataViewRequireArrayBuffer(args[0])` 要求第一参是 ArrayBuffer（含 SharedArrayBuffer）；`byte_offset` 有第二参就 `typedArrayConstructToIndex` 做 ToIndex（会跑用户 `valueOf`），否则 0；`view_length` 只在有第三参**且不是 undefined** 时才 ToIndex，否则 null 表示「跟随 buffer 长度」。最后 `dataViewValidateConstructorRange` 一次性校验 offset/length 落在 buffer 内。返回的结构体额外带一个 `has_offset`（`args.len >= 2`），调用方用它区分「显式传了 0」与「没传」。
- **所有权 / 错误 / 调用**：返回的是纯值结构体（两个整数加一个 bool），不分配、不建根。错误：`error.TypeError`（缺参 / 非 ArrayBuffer）、`error.RangeError`（范围校验失败）、ToIndex 跑用户代码冒出的 `error.JSException`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方：`src/exec/call_runtime.zig:2331` 与 `src/exec/class_init_ops.zig:100`（后者经 47 行的 `const` 别名）。

### `dataViewAccessor` (`src/exec/builtin_glue.zig:328`)

- **签名**：`pub fn dataViewAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue`。
- **作用**：`DataView.prototype` 的 buffer / byteLength / byteOffset 三个 accessor 体。
- **实现**：接收者必须是 dataview class，否则 TypeError；按名字返回 buffer 值或经 `core.typed_array` 算出的 byteLength / byteOffset；未知名字 TypeError。
- **所有权 / 错误 / 调用**：`buffer` 分支返回 `object.typedArrayBuffer()` 的**借用**值（不新建、不 retain）；另两个分支返回立即数 `int32`。不建根。按名字（而不是 id）分派，末尾兜底 `error.TypeError`。错误：非对象 / class 不是 `dataview` / 名字不认识一律 `error.TypeError`，加上 `dataViewByteLength` / `dataViewByteOffset` 对已 detach buffer 的报错。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方是本文件的 `bufferNativeRecord`（`src/exec/builtin_glue.zig:255`）。

### `dataViewGetCall` (`src/exec/builtin_glue.zig:343`)

- **签名**：`pub fn dataViewGetCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, method_id: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`DataView.prototype.getX` 的参数强制转换 + 转发。
- **实现**：`dataViewRequire` 校验接收者；下标经 `typedArrayConstructToIndex`；`littleEndian` 取第二参的真值；再调 `core.typed_array.dataViewGet`。
- **所有权 / 错误 / 调用**：`call_args` 是 2 元素**栈**数组，只在调用期间存在、不需要释放。不分配持久对象、不建根。错误：`dataViewRequire` 的 `error.TypeError`、`typedArrayConstructToIndex` 的 `error.RangeError` 与它跑用户 `valueOf` 时冒出的 `error.JSException`、`dataViewGet` 的越界 `error.RangeError`。`littleEndian` 参数只做 `isTruthy`，不跑 ToBoolean 用户代码。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方：`src/exec/call_runtime.zig:1378` 与本文件 `bufferNativeRecord`（270），两处都把 `error.TypeError` / `error.RangeError` 显式 `switch` 原样透传。

### `dataViewSetCall` (`src/exec/builtin_glue.zig:359`)

- **签名**：`pub fn dataViewSetCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, method_id: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`DataView.prototype.setX` 的参数强制转换 + 转发。
- **实现**：`dataViewRejectImmutable` 先拒不可变 buffer；下标经 `typedArrayConstructToIndex`；值经 `dataViewSetCoerceValue`；`littleEndian` 取第三参真值；再调 `core.typed_array.dataViewSet`。
- **所有权 / 错误 / 调用**：与 `dataViewGetCall` 同形，`call_args` 是 3 元素栈数组。顺序是规范要求的：先 `dataViewRejectImmutable`，再 ToIndex 下标，**再**强制转换待写值（`dataViewSetCoerceValue`），最后才读 littleEndian——三步里前两步都可能跑用户代码，顺序换了可观察行为就变了。错误同 get 侧，另加值强制转换的 `error.TypeError`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方：`src/exec/call_runtime.zig:1385` 与本文件 `bufferNativeRecord`（286）。

### `dataViewSetCoerceValue` (`src/exec/builtin_glue.zig:386`)

- **签名**：`pub fn dataViewSetCoerceValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, method_id: u32, value: core.JSValue, ) !core.JSValue`。
- **作用**：`DataView.prototype.setX` 的值强制转换：BigInt 视图收 BigInt，其余收 Number。
- **实现**：先 ToPrimitive；`method_id` 命中 BigInt64 / BigUint64 两个具名常量时直接返回该原始值；其余若是 BigInt 抛 TypeError，否则 ToNumber。
- **所有权 / 错误 / 调用**：不分配、不建根。`method_id == 9 or 10`（BigInt64 / BigUint64 两个 setter）时**直接返回原始值不做 ToNumber**，由下游的 `dataViewSet` 负责 BigInt 转换；其余 method_id 拒绝 BigInt（`error.TypeError`）再走 ToNumber。`toPrimitiveForNumber` 会跑用户 `valueOf`，可冒 `error.JSException`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方是本文件的 `dataViewSetCall`（`src/exec/builtin_glue.zig:369`）。两个 kind id 现在是本文件的 comptime 具名常量 `data_view_set_kind_big_int64` / `…_big_uint64`，由 `buffer_id_lookup.dataViewSetKindFromRecordId(@intFromEnum(DataViewSetMethod.big_int64/big_uint64))` 反查得到，所以 `DataViewSetMethod` 重排也不会静默错位（原先是硬编码的 9 / 10）。

### `errorIsError` (`src/exec/builtin_glue.zig:401`)

- **签名**：`pub fn errorIsError(args: []const core.JSValue) core.JSValue`。
- **作用**：`Error.isError` 的体。
- **实现**：无参或参数不是对象返回 false；否则判 `class_id == core.class.ids.error_`。
- **所有权 / 错误 / 调用**：无：三行判定，不分配、**无 error set**（返回裸 `core.JSValue` 而不是 `!core.JSValue`，是 builtin_glue 里少见的不返回 error 的函数）。缺参数、非对象、class 不是 `error_` 都返回 `false` 而不报错。唯一调用方 `src/exec/call_runtime.zig:1174` 的名字级联（`Error.isError`）。

### `weakRefEntry` (`src/exec/builtin_glue.zig:424`)

- **签名**：`fn weakRefEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 构造 `.weak_ref` 域三条记录之一的声明：`WeakRef.prototype.deref`、`FinalizationRegistry.prototype.register` 与 `unregister`。
- **实现**：返回一个字段写死的 `InternalEntry`：`.magic = @intCast(id)`（即 domain-local id，三条记录因此共用同一个入口函数）、`.cproto = .generic_magic`、`.native_function = builtin_dispatch.genericMagicFunction(&weakRefCall)`。三个调用点给的 (name, length, id) 分别是 `("deref", 0, .deref)`、`("register", 2, .finrec_register)`、`("unregister", 1, .finrec_unregister)`。
- **所有权 / 错误 / 调用**：无：comptime 构造一条 `InternalEntry` 字面量，不分配、无 error set。三个字段值得注意：`magic` 直接等于 `id`（域内 id 同时当 magic 用），`cproto` 固定 `.generic_magic`，`native_function` 是 `builtin_dispatch.genericMagicFunction(&weakRefCall)` 包出来的共享 handler 指针——所以三条记录共用同一个函数体，靠 magic 分流。3 个调用点全在紧接着的 `internal_entries` 表初始化里（`src/exec/builtin_glue.zig:407-409`）。

### `weakRefCall` (`src/exec/builtin_glue.zig:439`)

- **签名**：`fn weakRefCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.weak_ref` 域三条记录共用的入口函数：复原调用环境后按 magic 把请求转给 `WeakRef.prototype.deref` / `FinalizationRegistry.prototype.register` / `unregister` 的实现体。
- **实现**：`builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic)` 从 `runtime.active_native_call` 复原出 ctx / this / args / magic，复原失败（没有活跃 native 调用环境）即 `error.TypeError`；随后三臂 switch 按 `WeakRefPrototypeMethod` 转发，未知 magic 同样 `error.TypeError`。接收者的 class 检查留在各实现体里（`weakRefDerefCall` 先 `objectFromValue` 再比 `class_id != weak_ref`），所以方法被偷去用在异类接收者上仍抛 TypeError，与 qjs 的 `JS_GetOpaque2`（quickjs.c:61188）等价。
- **所有权 / 错误 / 调用**：共享 handler：先 `builtin_dispatch.nativeCall(...)` 从原生调用参数还原出 `NativeCall` 视图（拿不到即 `error.TypeError`），再按 `magic` 三选一转发；自身不分配、不建根。错误：未知 magic 的 `else => error.TypeError`，以及三个被转发函数的 `error.TypeError` / 分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 **没有直接调用方**：它的地址由 `weakRefEntry`（`src/exec/builtin_glue.zig:419`）烘进 `internal_entries` 的 `native_function` 字段，由 VM 的记录分发按 `(.weak_ref, id)` 打进来。

### `weakRefDerefCall` (`src/exec/builtin_glue.zig:457`)

- **签名**：`pub fn weakRefDerefCall(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：WeakRef / FinalizationRegistry 方法体。
- **实现**：接收者必须是对象且 `class_id == weak_ref`，否则 TypeError；随后 `object.weakRefDeref(rt)`。
- **所有权 / 错误 / 调用**：`object.weakRefDeref(rt)` 返回的是弱引用目标的值——对象还活着就是它的**借用**值，已被回收就是 undefined；本函数不分配、不建根、不 retain。错误只有 `error.TypeError`（receiver 非对象或 class 不是 `weak_ref`）——注释点明这条 class 检查是为了让「偷来的方法作用在外来 receiver 上」仍然像名字级联时代那样抛 TypeError（对标 qjs `JS_GetOpaque2`）。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方是本文件的 `weakRefCall`（`src/exec/builtin_glue.zig:438`）。

### `finalizationRegistryRegister` (`src/exec/builtin_glue.zig:463`)

- **签名**：`pub fn finalizationRegistryRegister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：WeakRef / FinalizationRegistry 方法体。
- **实现**：五道前置检查后追加一条 cell。依次：receiver 必须是对象且 `class_id == finalization_registry`（否则 `error.TypeError`）；取 `target` / `held_value` / `unregister_token` 三个参数，缺的填 undefined；`core.symbol.canBeHeldWeakly(target)` 必须为真；`target.sameValue(held_value)` 为真即 `error.TypeError`（held value 不能就是 target）；`unregister_token` 非 undefined 时也必须可弱持有。全过后 `finalizationRegistryAppendCell` 追加，返回 undefined。源码注释特别标明**没有**自注册排除：对标 qjs `js_finrec_register`（quickjs.c:61318），registry 可以把自己登记成 target，因为 cell 对它只持弱引用。
- **所有权 / 错误 / 调用**：三个参数值都只是传递给 cell（cell 内对 target / token 持弱引用，对 held value 持强引用），本函数不 retain、不建根。错误：五处 `error.TypeError` 加 `appendFinalizationRegistryCell` 的分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方是本文件的 `weakRefCall`（`src/exec/builtin_glue.zig:439`）。

### `finalizationRegistryUnregister` (`src/exec/builtin_glue.zig:479`)

- **签名**：`pub fn finalizationRegistryUnregister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：WeakRef / FinalizationRegistry 方法体。
- **实现**：receiver 必须是对象且 `class_id == finalization_registry`，否则 `error.TypeError`；取第一参当 token（缺则 undefined），要求 `core.symbol.canBeHeldWeakly` 为真；随后 `object.unregisterFinalizationRegistryCells(ctx.runtime, token)` 删掉所有匹配该 token 的 cell，把它返回的 bool 装成 `JSValue.boolean`。
- **所有权 / 错误 / 调用**：不分配、不建根；返回的 bool 是 `unregisterFinalizationRegistryCells` 报告的「有没有真删掉条目」。错误：receiver 非 `finalization_registry` 或 token 不可弱持有时 `error.TypeError`（缺参数时 token 是 undefined，`canBeHeldWeakly(undefined)` 为假，所以无参调用也是 TypeError）。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方是本文件的 `weakRefCall`（`src/exec/builtin_glue.zig:440`）。

### `finalizationRegistryAppendCell` (`src/exec/builtin_glue.zig:487`)

- **签名**：`pub fn finalizationRegistryAppendCell( rt: *core.JSRuntime, object: *core.Object, target: core.JSValue, held_value: core.JSValue, unregister_token: core.JSValue, ) !void`。
- **作用**：把一条 (target, heldValue, unregisterToken) cell 追加进 FinalizationRegistry。
- **实现**：单行转发 `object.appendFinalizationRegistryCell(rt, target, held_value, unregister_token)`——所有检查都在调用方 `finalizationRegistryRegister` 里做完了，这里只负责把四个值交给对象侧的 cell 链表。之所以单独存在，是为了给测试一个不带检查的追加入口。
- **所有权 / 错误 / 调用**：cell 的分配与 GC 边登记全在 `Object.appendFinalizationRegistryCell` 里（对 `target` / `unregister_token` 建弱边、对 `held_value` 建强边）；本函数不分配、不建根。错误只有分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 两个调用方：本文件的 `finalizationRegistryRegister`（`src/exec/builtin_glue.zig:463`）与 `src/exec/call_runtime.zig:2502` 的测试「finalizationRegistryAppendCell roots direct symbol fields while allocating cell」——那个测试正是为了证明分配 cell 期间直接传进来的 symbol 字段被正确 root 住。

### `symbolFor` (`src/exec/builtin_glue.zig:497`)

- **签名**：`pub fn symbolFor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Symbol.for(key)`：把参数字符串化后到 runtime 的全局 symbol 注册表里查/建对应 symbol（`keyFor` 是隔壁的 `symbolKeyFor`，well-known symbol 的安装在 `standard_globals.defineWellKnownSymbol`）。
- **实现**：有参数就 `toStringBytesForSymbol` 取字节，无参数则 dup 出 "undefined"；`defer` 释放该缓冲后走 `ctx.runtime.globalSymbolValue(key)`。
- **所有权 / 错误 / 调用**：⚠️ **本册里唯一一个真有堆上局部缓冲的函数**：`key` 要么来自 `toStringBytesForSymbol`（被调方分配），要么是 `allocator.dupe(u8, "undefined")`，两条路都由本函数 `defer ctx.runtime.memory.allocator.free(key)` 释放。返回的 symbol 值来自 `rt.globalSymbolValue(key)`——全局 symbol 注册表持有它，不是新所有权。错误：`toStringBytesForSymbol` 跑用户 `toString` 时的 `error.JSException`、Symbol 入参的 `error.TypeError`，加分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/primitive_ops.zig:194`（`Symbol.for`）。

### `symbolKeyFor` (`src/exec/builtin_glue.zig:514`)

- **签名**：`pub fn symbolKeyFor(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Symbol.keyFor(sym)`：反向查询——参数必须是 Symbol，若它是 `Symbol.for` 登记进全局注册表的那种就返回它的键字符串，否则返回 undefined（正向的 `Symbol.for` 是上面的 `symbolFor`）。
- **实现**：缺参用 undefined；参数必须是 Symbol（`asSymbolAtom` 失败即 TypeError）；注册表里查不到返回 undefined，否则把键字符串造成 JS 字符串。
- **所有权 / 错误 / 调用**：`registryKey` 返回的是 atom 表里的**借用**字节切片，`createStringValue` 拷成新字符串值再返回；不建根。错误只有 `error.TypeError`（参数不是 Symbol；缺参数时是 undefined，同样 TypeError）与建字符串的分配失败——**不在注册表里不是错误**，返回 undefined。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/primitive_ops.zig:203`（`Symbol.keyFor`）。

### `createDataFunction` (`src/exec/builtin_glue.zig:523`)

- **签名**：`pub fn createDataFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !core.JSValue`。
- **作用**：C_FUNCTION_DATA 的类比物：造一个语义上使用调用方 realm（而非载体构造 realm）的内部回调函数。
- **实现**：从 global 取 Function.prototype（缺则 `error.InvalidBuiltinRegistry`），再 `core.function.nativeDataFunctionWithPrototype`。
- **所有权 / 错误 / 调用**：返回**新建**的 data-function 值，所有权交给调用方（各调用点都立刻把它塞进 promise reaction / disposable 回调槽里）。`function_proto` 是从 global 借出的。错误：`functionPrototypeFromGlobal` 拿不到即 `error.InvalidBuiltinRegistry`，加分配失败。语义要点写在注释里——C_FUNCTION_DATA 类比，这类回调**用调用方 realm 而不是载体建立时的 realm**。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 8 个调用方跨 4 个文件：`src/exec/promise_ops.zig:1849`/2049/3291/3444/3490、`src/exec/array_ops.zig:3999`、`src/exec/disposable_ops.zig:539`、`src/exec/async_generator.zig:180`。

### `constructCollectionFromVm` (`src/exec/builtin_glue.zig:528`)

- **签名**：`pub fn constructCollectionFromVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, kind: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：VM 侧构造集合：先解出 constructor 的 `prototype`，再交给 `object_ops.constructCollectionWithPrototypeFromVm`。
- **实现**：`constructorPrototypeObject` 拿到带所有权的原型句柄，`defer prototype.deinit(rt)` 释放，中间用 `prototype.object()`。
- **所有权 / 错误 / 调用**：⚠️ 这里有一个**真的 owned 句柄**：`var prototype = try constructorPrototypeObject(...); defer prototype.deinit(ctx.runtime);`——原型是带引用的句柄，必须在本函数内 deinit，传给下游的只是 `prototype.object()` 借用指针。返回的集合对象是新建的，所有权交给调用方。错误：取原型时的 `error.TypeError` + 构造集合的分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/call_runtime.zig:2324`（`new Map()` / `new Set()` 等经 `collection.constructorId(name)` 认出 kind 之后）。

### `addCollectionEntriesFromIterator` (`src/exec/builtin_glue.zig:541`)

- **签名**：`pub fn addCollectionEntriesFromIterator( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, collection_value: core.JSValue, kind: u32, iterable_value: core.JSValue, adder: core.JSValue, ) !void`。
- **作用**：集合构造器的填充循环：从 iterable 取迭代器，逐项调 adder（Map/WeakMap 拆 [k,v]）。
- **实现**：先 `getIteratorMethod` 并要求可调用，调用得到迭代器对象。随后一条 dense 批量填充快路径，只在默认 Array 迭代协议可证完好时才走：迭代器是 value kind 的默认 Array Iterator、游标还在 0、`next` 是内建、adder 也是 `.collection` domain 的内建 add/set、目标是无洞的 fast array；命中就 `array_ops.addCollectionEntriesFromArray` 一次性填完并把游标直接推到末尾（失败要先 `iteratorCloseWithCompletionAndPropagate`）。否则逐步 `iteratorStepValue`，任一步出错都先关闭迭代器再传播。
- **所有权 / 错误 / 调用**：本文件最重的一个。所有权上不新建长期对象，但**错误路径有严格协议**：慢路径的每一个可能失败点（`iteratorStepValue`、取 entry 的 0/1 下标、调 adder）都用 `catch |err| return iteratorCloseWithCompletionAndPropagate(...)` 包住，保证在把错误抛出去之前先跑迭代器的 `return`（IteratorClose）；快路径的 `addCollectionEntriesFromArray` 同样这么包。快路径还有一整套「默认 Array 迭代协议可证完好」的守卫（`next` 是内建、iterator class 是 `array_iterator`、kind 是 value、游标未动、adder 是内建 collection 记录、target 是无洞 fast array），注释说明了为什么必须全中：批量填充只在最后动一次游标、也不跑逐元素 IteratorClose，所以任何用户可见的 `add`/`set` 都会观察到差异。错误：`error.TypeError`（`@@iterator` 不可调用、entry 不是对象）+ 用户代码冒上来的任意 `error.JSException`。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/object_ops.zig:1564`（经 52 行的 `const` 别名）。

### `callCollectionAdderFromVm` (`src/exec/builtin_glue.zig:624`)

- **签名**：`pub fn callCollectionAdderFromVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, collection_value: core.JSValue, adder: core.JSValue, args: []const core.JSValue, ) !void`。
- **作用**：以集合为 `this` 调用 adder（add / set），结果丢弃。
- **实现**：`_ = try callValueOrBytecodeRoot(ctx, output, global, collection_value, adder, args, null, null);` 一行——把 `collection_value` 当 `this`、`adder` 当被调函数发起一次通用调用，结果丢弃（`add`/`set` 的返回值在这个语境下没用）。最后两个 null 是 caller bytecode / frame：**不传调用方上下文**，所以被调方拿不到内联缓存提示。`callValueOrBytecodeRoot` 的 `Root` 后缀意味着它会给参数建根，能安全地跑用户 `add` / `set` 覆写。
- **所有权 / 错误 / 调用**：自身不分配、不建根（根在 `callValueOrBytecodeRoot` 里建）；`args` 是调用方栈上的 1 或 2 元素数组。错误：被调 adder 可能是用户函数，任何 `error.JSException` 都会从这里冒上去——调用方 `addCollectionEntriesFromIterator` 正是为此把每次调用都包在 IteratorClose 里。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 4 个调用点跨两个文件：`src/exec/array_ops.zig:1317`/1319（经 52 行别名）与本文件 `addCollectionEntriesFromIterator`（601/605）。

### `functionConstructorFromGlobal` (`src/exec/builtin_glue.zig:639`)

- **签名**：`pub fn functionConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：从 global 借出 `Function` 构造器对象。
- **实现**：`global.getOwnDataObjectBorrowed(core.atom.ids.Function)`，没有返回 null。
- **所有权 / 错误 / 调用**：无：`rt` 形参不被读取（纯借用读，保留是为了与调用方并排使用的同族 `*FromGlobal` realm 槽 helper 同形，函数头注释已写明），只 `getOwnDataObjectBorrowed(core.atom.ids.Function)` 读一次 global 的自有属性，返回**借用**指针或 null；不分配、无 error set。注意它读的是可变的 `globalThis.Function` 绑定（不是 realm 缓存槽），所以用户改写 `Function` 会被它看见。3 个调用点跨两个文件：`src/exec/object_ops.zig:258`、`src/exec/promise_ops.zig:144`/209（两个文件各在顶部 75 / 72 行起了 `const` 别名），用途都是给新造的构造器对象设 `[[Prototype]]`。

### `storeRealmValue` (`src/exec/builtin_glue.zig:647`)

- **签名**：`pub fn storeRealmValue(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, value: core.JSValue) !void`。
- **作用**：往 global 的 realm 缓存槽写一个值。
- **实现**：`try global.setCachedRealmValue(rt, slot, value);` 一行转发。存在的意义是给 `object_ops` / `call_runtime` 一个不必直接碰 `core.object.RealmValueSlot` 写入 API 的名字；`global` 必须已经有 global payload，否则 `setCachedRealmValue` 内部报错。
- **所有权 / 错误 / 调用**：写进去的值从此由 realm 槽持有，**这是一条 GC 强边**——`object_ops.zig:1003` 的注释就点明「在 `storeRealmValue` 发布之前这个半成品原型没有任何持有者」。本函数自身不分配、不建根。错误只有槽写入的分配失败。12 个调用点跨 3 个文件：`src/exec/object_ops.zig:231`/261/266/1026/2194（经 100 行别名）、`src/exec/promise_ops.zig:150`/151/171/184/212/217（经 91 行别名）与 `src/exec/call_runtime.zig:4353`。

### `defineNativeDataMethod` (`src/exec/builtin_glue.zig:657`)

- **签名**：`pub inline fn defineNativeDataMethod(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32) !void`。
- **作用**：在对象上装一个**不带** native 记录 id 的原生方法（可写 / 不可枚举 / 可配置的数据属性），因此它的调用仍走 `callNativeCallableByName` 的名字级联。
- **实现**：`inline` 包装，转 `defineNativeDataMethodMaybeId(..., native_builtin_id = null)`；实体里用 `core.function.nativeFunctionForGlobal(rt, global, core.atom.predefinedName(atom_id), length)` 建函数对象，`null` 分支跳过 `setNativeBuiltinIdAndRecord`，最后 `object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true))`。与 `defineNativeDataMethodWithNativeId` 共享同一个 `noinline` 实体，差别只有那个 `?i32`。
- **所有权 / 错误 / 调用**：`inline` 包装，转给 `defineNativeDataMethodMaybeId`（`src/exec/builtin_glue.zig:654`）并把 `native_builtin_id` 传 null——即**不盖记录 id**，这类方法的调用走 legacy 名字链。那边新建的函数对象由 `defineOwnProperty` 写进属性表（flags 固定 `{writable=true, enumerable=false, configurable=true}`），不建根。错误：`expectObject` 失败时 `error.TypeError` + 分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 只有 2 个调用点：`src/exec/object_ops.zig:2188`/2190（经 71 行别名，给 wrap-for-valid-iterator 原型装 `next` / `return`）；`src/tests/exec.zig:11394` 那条同名回归测试是纯 JS 断言，并不直接调用它。

### `defineNativeDataMethodWithNativeId` (`src/exec/builtin_glue.zig:664`)

- **签名**：`pub inline fn defineNativeDataMethodWithNativeId(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32, native_builtin_id: i32) !void`。
- **作用**：同 `defineNativeDataMethod`，但给函数对象盖 native-builtin record id，调用走整数记录而不是遗留名字链。
- **实现**：`defineNativeDataMethodMaybeId(..., native_builtin_id)`。
- **所有权 / 错误 / 调用**：`inline` 包装，本身不分配、不建根；函数对象在被转发的实体里新建并由 `defineOwnProperty`（flags `{writable=true, enumerable=false, configurable=true}`）交给目标对象。与 `defineNativeDataMethod` 的唯一差别是 `native_builtin_id` 传的是真 id，因此函数对象会被 `setNativeBuiltinIdAndRecord` 盖上记录、调用走整数分发而不是名字级联。错误：`expectObject` 失败的 `error.TypeError` 加建函数 / define 的分配失败，一路 `try` 上抛。4 个调用方：`src/exec/object_ops.zig:243`/244（generator 原型的 `return` / `throw`）、`src/exec/iterator_ops.zig:1053`、`src/exec/string_ops.zig:2186`（String 迭代器的 `next`）。

### `defineNativeDataMethodMaybeId` (`src/exec/builtin_glue.zig:668`)

- **签名**：`noinline fn defineNativeDataMethodMaybeId( rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32, native_builtin_id: ?i32, ) !void`。
- **作用**：native 数据方法定义的 leftover 走法：`nativeFunctionForGlobal` + 可选 stamp + `defineOwnProperty`。comptime 身份只是「要不要盖 native id」。
- **实现**：`core.function.nativeFunctionForGlobal(rt, global, predefinedName(atom_id), length)`。若 `native_builtin_id` 有值：`expectObject` 失败 → `error.TypeError`，否则 `setNativeBuiltinIdAndRecord`。最后 `object.defineOwnProperty(rt, atom_id, Descriptor.data(method, writable, non-enumerable, configurable))`。`defineNativeDataMethod` / `WithNativeId` 是 inline 包装。
- **所有权 / 错误 / 调用**：方法对象由 defineOwnProperty 接到目标。async-generator / iterator-helper 戳故意不折进本函数（knife 93），走 `defineStampedNativeDataMethod`。

### `defineStampedNativeDataMethod` (`src/exec/builtin_glue.zig:692`)

- **签名**：`pub noinline fn defineStampedNativeDataMethod( rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32, stamp: NativeDataMethodRareStamp, helper_id: i32, ) !void`。
- **作用**：造一条 native 数据方法后盖稀有 payload 戳：async-generator 原型方法，或 iterator-helper 方法号。
- **实现**：`nativeFunctionForGlobal` 用 predefined 名。`expectObject` 失败 → TypeError。`.async_generator` → `addAsyncGeneratorPrototypeMethod`，失败 TypeError。`.iterator_helper` 要求 `helper_id` 为 1 或 2，再 `addIteratorHelperMethod`。最后 `defineOwnProperty` 成 writable/non-enumerable/configurable 数据属性。outlined leftover：`defineAsyncGeneratorDataMethod` / `installIteratorHelperMethod`。故意不折进 `defineNativeDataMethodMaybeId`（knife 93）。
- **所有权 / 错误 / 调用**：方法对象由 defineOwnProperty 接到目标。Promise/iterator 安装路径。

### `defineNativeDataMethodNamedWithNativeId` (`src/exec/builtin_glue.zig:717`)

- **签名**：`pub fn defineNativeDataMethodNamedWithNativeId(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, name: []const u8, length: i32, native_builtin_id: i32) !void`。
- **作用**：名字来自运行时表（而不是预定义 atom 常量）的那条 native 数据方法定义，唯一调用方是 `object_ops` 的 CallSite 原型。
- **实现**：`rt.internAtom(name)` 取键并 `pinForHost` / `defer unpinForHost`，`nativeFunctionForGlobal` 造函数（非对象则 TypeError），`setNativeBuiltinIdAndRecord` 盖记录，最后 `defineOwnProperty` 成可写、不可枚举、可配置的数据属性。
- **所有权 / 错误 / 调用**：`rt.internAtom(name)` 之后立刻 `rt.atoms.pinForHost` 并配 `defer rt.atoms.unpinForHost`（两者对 const / tagged-int id 都是 no-op），与 `standard_globals.temporaryStringAtom` 同一个 TGC S3 §4 class B 协议：非预定义名 intern 出来的裸 id 要跨过随后两次会分配的调用才被属性表接管。新建的函数对象也当场写进属性表，不建根。它与 `defineNativeDataMethodWithNativeId` 的唯一区别是收字节串而不是预定义 atom——注释点明这是为了那个方法名来自表而不是常量的调用方。错误：`expectObject` 失败的 `error.TypeError` + intern / 建函数 / define 的分配失败。错误一路 `try` 上抛到 VM 的 native 终端（`builtin_dispatch.nativeFromHostError` → `materializeRuntimeError`）才建 Error 对象、装 pending exception 并换成哨兵，本函数自己不碰 pending。 唯一调用方 `src/exec/object_ops.zig:1020`（CallSite 原型的方法表）。


## `src/exec/internal_builtins.zig` — 编译期记录表

把各 domain 的 `internal_entries` 收成 `table: [domain_count]EntryTable`。`installStandardGlobals` 把 `JSRuntime.internal_builtins` 指过来。slot 0 不用；`.host` 故意留空（host 走另一条分发）。

dense 前缀 + sparse 尾：空洞不占 `NativeEntry`。另有枚举→记录连通性门，防止「id 能解码、表里没有」。


### `checkedRecord` (`src/exec/internal_builtins.zig:52`)

- **签名**：`fn checkedRecord(comptime entry: InternalEntry) NativeEntry`。
- **作用**：把一条 `InternalEntry` 经唯一 comptime 适配器变成 `NativeEntry`（校验也在适配器里）。
- **实现**：返回 `native_legacy.entryFromInternal(entry)`。
- **所有权 / 错误 / 调用**：comptime。id 0 与重复 id 由 `recordTable` 拒绝。

### `recordTable` (`src/exec/internal_builtins.zig:56`)

- **签名**：`fn recordTable(comptime entries: []const InternalEntry) EntryTable`。
- **作用**：把一个 domain 的 InternalEntry 切片收成 dense 前缀 + 按 id 排序的 sparse 尾，使空洞不占空记录。
- **实现**：扫 max_id、占位、拒绝 id 0 与重复。对每个 occupied 切点算 dense+sparse 字节，取最小。dense 填 `retired_entry`，occupied 写入；sparse 插入排序。
- **所有权 / 错误 / 调用**：comptime，`@setEvalBranchQuota(400_000)`。结果是 `JSRuntime.internal_builtins` 的一档。

### `assertIdEnumHasRecord` (`src/exec/internal_builtins.zig:186`)

- **签名**：`fn assertIdEnumHasRecord(comptime binding: IdEnumBinding) void`。
- **作用**：编译期断言方法 id 枚举的每个成员在该 domain 的记录表里都能 `get` 到。
- **实现**：对 `binding.Ids` 每个 field，`records.get(field.value)` 为空则 `@compileError`，防止「id 能解码但表里没有、调用掉进 name cascade」。
- **所有权 / 错误 / 调用**：与 `recordTable` 的 entries→records 方向相反；两者一起构成连通性门。


## `src/exec/open_bindings.zig` — 开绑定表

帧局部/参数的开 `VarRef` 表，按下标记录每个捕获绑定当前唯一的活 cell。`close` 从帧存储摘下 cell（身份不变）。

取 cell 的那一半（qjs `get_var_ref`，quickjs.c:16997-17044）**不在这里**：它被各内联了一份进 `Frame.captureLocal` 与 `Frame.captureArg`（`src/exec/frame.zig:570`/`598`），以保持 js_closure2 嵌套循环只过一个 helper 边界。原来并存的 `Table.acquire` 零调用方，已删；改两处 capture 时须同步。

### 类型

- `Table.cells`：`[]?*VarRef`，按下标与帧槽对应。（原 `Flags` 只服务 `acquire`，一并删除。）


### `Table.close` (`src/exec/open_bindings.zig:16`)

- **签名**：`pub fn close(self: *Table, rt: anytype, binding_index: u16) !void`。
- **作用**：关闭一个下标上的开绑定：从表摘下并 `cell.close`。
- **实现**：越界 InvalidBytecode；空槽直接返回。
- **所有权 / 错误 / 调用**：表侧引用释放；cell 身份仍可被闭包持有。

### `Table.closeAll` (`src/exec/open_bindings.zig:24`)

- **签名**：`pub fn closeAll(self: *Table, rt: anytype) void`。
- **作用**：关闭表中全部开 cell。
- **实现**：遍历 `cells`，非空则置 null 并 `close`。
- **所有权 / 错误 / 调用**：帧销毁路径。无 error。

### `Table.hasOpen` (`src/exec/open_bindings.zig:32`)

- **签名**：`pub fn hasOpen(self: *const Table) bool`。
- **作用**：是否还有未关闭的开绑定。
- **实现**：任一 `cells[i] != null` 则为 true。
- **所有权 / 错误 / 调用**：只读。

## 覆盖核对

- 清单函数数: 244（`src/exec/builtin_dispatch.zig` 77 + `src/exec/builtin_glue.zig` 35 + `src/exec/internal_builtins.zig` 3 + `src/exec/open_bindings.zig` 3 + `src/exec/standard_globals.zig` 126）
- 本文标题覆盖: 244
- 未覆盖: 无
