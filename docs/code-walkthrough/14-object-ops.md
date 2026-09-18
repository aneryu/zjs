# 14c — `object_ops.zig`：原型、闭包函数对象、构造

[`src/exec/object_ops.zig`](../../src/exec/object_ops.zig) 是 exec 层对象/属性/原型/Proxy/函数对象算法的主文件（约 5k 行）。参数默认 borrowed，返回 owned `JSValue`。`ctx/output/global/caller_function/caller_frame` 必须显式：线程上的 `global` 是跨 realm 权威，不一定是 `ctx.globalObject()`。热路径不得与冷泛化路径共享。对照 `quickjs.c:7995-8011`、`17228-17417`。

后续分册：[对象/迭代/arguments](14-object-ops-objects.md)、[Get/Set/Has/Delete](14-object-ops-get-set.md)、[brand/Proxy](14-object-ops-proxy.md)。

## 本文件前半类型

`Step`：`.done` / `.continue_loop`，给 outlined opcode 告诉分发器是否已转入 catch。

`ClosureCellResolver`：自定义捕获解析回调（`resolve: *const fn (...) HostError!*VarRef`）。

`ClosureCaptureSource`：`.nested_frame` / `.root_global` / `.custom`。

`OwnedPrototype`：可观察的 `constructor.prototype` 查找结果。Proxy/getter 可能返回只有这一份引用的新对象；调用方必须把 handle 活到 `object()` 被新实例 shape 保留之后再 `deinit`。

大量 `call_runtime` / `array_ops` / `builtin_glue` 别名见文件顶部，此处不重复。

---

### `objectPrototypeFromGlobal` (`src/exec/object_ops.zig:120`)

- **签名**：`pub fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：O(1) 取 `%Object.prototype%`，避免每次 `{}` 分配走两趟属性哈希。
- **实现**：`cachedRealmValue(.object_prototype)`；否则 `ctx.classPrototypeObject(object)`；再否则 `constructorPrototypeFromGlobalAtom(..., Object)`。`Object.prototype` 不可写不可配置，缓存不会过期。
- **所有权 / 错误 / 调用**：borrowed 指针。空对象分配热路径。

### `constructorPrototypeFromGlobal` (`src/exec/object_ops.zig:140`)

- **签名**：`pub fn constructorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object, constructor_name: []const u8) ?*core.Object`。
- **作用**：`global[name].prototype` 的全局绑定走查。
- **实现**：`internAtom` 失败 `null`；转 Atom 版。spec 要求 realm intrinsic 的路径禁止走这里。
- **所有权 / 错误 / 调用**：embedder 回退；标准装箱用 class 表。

### `constructorPrototypeFromGlobalAtom` (`src/exec/object_ops.zig:145`)

- **签名**：`pub fn constructorPrototypeFromGlobalAtom(rt: *core.JSRuntime, global: *core.Object, constructor_atom: core.Atom) ?*core.Object`。
- **作用**：已有 atom 的 `global[ctor].prototype` own-data 走查。
- **实现**：两层 `getOwnDataObjectBorrowed`；`rt` 形参不被读取（纯借用读），保留是为了与同族 `*PrototypeFromGlobal*` 一致，函数头注释已写明。
- **所有权 / 错误 / 调用**：不跑 getter。替换 `globalThis.String` 在标准装箱上不可观察。

### `functionPrototypeFromGlobal` (`src/exec/object_ops.zig:156`)

- **签名**：`pub fn functionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：`%Function.prototype%`。
- **实现**：`constructorPrototypeFromGlobalAtom(..., Function)`。
- **所有权 / 错误 / 调用**：函数对象默认原型。

### `cachedRealmObject` (`src/exec/object_ops.zig:160`)

- **签名**：`pub fn cachedRealmObject(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot) ?*core.Object`。
- **作用**：把 realm 槽里的 JSValue 收成对象指针。
- **实现**：`cachedRealmValue` + `expectObject`，失败 `null`。
- **所有权 / 错误 / 调用**：各 `*PrototypeFromGlobal` 的第一臂。

### `primitivePrototypeFromRealmOrGlobal` (`src/exec/object_ops.zig:165`)

- **签名**：`pub fn primitivePrototypeFromRealmOrGlobal( rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, constructor_atom: core.Atom, ) ?*core.Object`。
- **作用**：原始值 `[[Get]]` 用的原型：对齐 `JS_GetPrototypePrimitive`（`quickjs.c:7995-8011`）。
- **实现**：realm 槽优先；未发布则全局走查。
- **所有权 / 错误 / 调用**：不物化包装对象。

### `primitivePrototypeForAccess` (`src/exec/object_ops.zig:181`)

- **签名**：`fn primitivePrototypeForAccess(rt: *core.JSRuntime, global: *core.Object, primitive: core.JSValue) ?*core.Object`。
- **作用**：按原始类型选 String/Number/Boolean/BigInt/Symbol 原型。
- **实现**：`isString/Number/Bool/BigInt/Symbol` 各走对应 realm slot。其它 `null`。
- **所有权 / 错误 / 调用**：`getPrimitiveProperty` / `primitiveObjectForAccess`。

### `materializeFrameThisBinding` (`src/exec/object_ops.zig:211`)

- **签名**：`pub fn materializeFrameThisBinding(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !core.JSValue`。
- **作用**：普通函数 ThisBinding 首次观察时物化：宽松 nullish → global，原始值 ToObject。
- **实现**：严格 / runtime-strict 原样返回 `frame.this_value`。已是对象原样。nullish 写入 `global.value()`。否则 `primitiveObjectForAccess` 写回帧槽，保证同一次调用包装身份稳定。对齐 qjs：`JS_CallInternal` 保持 raw `this_obj`，物化在 `OP_push_this`。箭头的词法 this 是闭包 cell，不看帧槽。
- **所有权 / 错误 / 调用**：direct eval 的普通函数共用。装箱失败上抛。

### `generatorPrototypeFromGlobal` (`src/exec/object_ops.zig:226`)

- **签名**：`pub fn generatorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：惰性创建 `%Generator.prototype%` 并写入 realm 槽。
- **实现**：缓存命中即返回。否则 create，原型为 Iterator.prototype 或 Object.prototype；`installGeneratorPrototypeProperties`；`storeRealmValue`。
- **所有权 / 错误 / 调用**：失败 `errdefer` destroy 未发布对象。

### `installGeneratorPrototypeProperties` (`src/exec/object_ops.zig:238`)

- **签名**：`pub fn installGeneratorPrototypeProperties(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !void`。
- **作用**：安装 `next`/`return`/`throw` 与 `Symbol.toStringTag = "Generator"`。
- **实现**：`nativeFunctionForGlobal("next")` 打上 `generator_next` builtin id 并 `addGeneratorNextFunction`。return/throw 走 `defineNativeDataMethodWithNativeId`。tag 不可枚举不可写可配置。
- **所有权 / 错误 / 调用**：仅惰性原型构建。

### `generatorFunctionPrototypeFromGlobal` (`src/exec/object_ops.zig:254`)

- **签名**：`pub fn generatorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object`。
- **作用**：惰性 `%GeneratorFunction.prototype%` 及其 constructor 环。
- **实现**：缓存；create 挂 Function.prototype；造 `GeneratorFunction` 构造器，realm/prototype 互指；`prototype` 指向 `generatorPrototypeFromGlobal`；`@@toStringTag`；两槽都 store。
- **所有权 / 错误 / 调用**：async 变体在 `promise_ops`。

### `createGlobalClosureVarRef` (`src/exec/object_ops.zig:281`)

- **签名**：`fn createGlobalClosureVarRef(ctx: *core.JSContext, global: *core.Object, cv: bytecode.function_bytecode.BytecodeClosureVar) !*core.VarRef`。
- **作用**：全局引用的捕获瀑布：词法 VARREF → 全局对象 VARREF 属性 → 共享 uninitialized 旁表。对照 `js_closure_global_var`（`quickjs.c:17228-17260`）。
- **实现**：`selectOrdinaryGlobalClosureCell`；`VarRef.fromValue` 失败 `InvalidBytecode`。**不管** 该闭包变量自己的 lexical 位。
- **所有权 / 错误 / 调用**：未声明名与后来的 `js_closure_define_global_var` 共用停放 cell。

### `bytecodeFunctionClassId` (`src/exec/object_ops.zig:288`)

- **签名**：`fn bytecodeFunctionClassId(fb: *const bytecode.FunctionBytecode) core.ClassId`。
- **作用**：func_kind → class：normal/generator/async/async_generator。
- **实现**：switch `functionKind()`。
- **所有权 / 错误 / 调用**：`js_closure` 的 `func_kind_to_class_id`。

### `createModuleBytecodeFunctionShell` (`src/exec/object_ops.zig:300`)

- **签名**：`pub fn createModuleBytecodeFunctionShell( ctx: *core.JSContext, fb: *const bytecode.FunctionBytecode, ) !*core.Object`。
- **作用**：给 canonical 模块根分配未发布的函数对象壳；调用方仍拥有 `fb`。
- **实现**：须 `isModule`，realm 即 `ctx`。`contextGlobal` 确保标准全局已物化。class + `bytecodeFunctionPrototypeForRealm` + `Object.create`。MODULE_DECL/IMPORT 表是链接器步骤。
- **所有权 / 错误 / 调用**：返回壳，尚未 attach bytecode/captures。

### `bytecodeFunctionPrototypeForRealm` (`src/exec/object_ops.zig:325`)

- **签名**：`fn bytecodeFunctionPrototypeForRealm( ctx: *core.JSContext, realm: *core.JSContext, class_id: core.ClassId, kind: bytecode.function_bytecode.FunctionKind, ) !*core.Object`。
- **作用**：从 FunctionBytecode 自己的 realm 解析不可变 intrinsic 原型。
- **实现**：`classPrototypeObject` 命中即返回。否则按 kind 惰性构建并 `setClassPrototype`。
- **所有权 / 错误 / 调用**：无 global → `InvalidBuiltinRegistry`。

### `ownedClosureCell` (`src/exec/object_ops.zig:361`)

- **签名**：`fn ownedClosureCell(_: *core.JSRuntime, owned: core.JSValue) !*core.VarRef`。
- **作用**：owned JSValue 必须已经是 cell。
- **实现**：`VarRef.fromValue` 否则 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：根闭包构造的收口。

### `createRootGlobalClosureCell` (`src/exec/object_ops.zig:371`)

- **签名**：`pub fn createRootGlobalClosureCell( ctx: *core.JSContext, global: *core.Object, fb: *const bytecode.FunctionBytecode, cv: bytecode.function_bytecode.BytecodeClosureVar, ) !*core.VarRef`。
- **作用**：根函数 GLOBAL/GLOBAL_DECL cell，位置对齐 qjs closure2 pass 2。
- **实现**：`.global`/`.global_ref` → `selectOrdinaryGlobalClosureCell`。`.global_decl`：lexical 则 `ensureGlobalLexicalCell`；否则 `ensureGlobalObjectVarRefCell`（eval / global function decl 标志），再不行退回 ordinary。其它 closure type `InvalidBytecode`。
- **所有权 / 错误 / 调用**：GLOBAL_DECL 元数据由声明 owner 助手盖；普通 GLOBAL 是纯别名。

### `resolveNestedClosureCell` (`src/exec/object_ops.zig:399`)

- **签名**：`inline fn resolveNestedClosureCell( ctx: *core.JSContext, frame: *frame_mod.Frame, global: *core.Object, cv: bytecode.function_bytecode.BytecodeClosureVar, ) !*core.VarRef`。
- **作用**：嵌套 `js_closure2` 的一个 closure_type 臂（`quickjs.c:17297-17331`）。
- **实现**：`.local` → `captureLocal`；`.arg` → `captureArg`；`.ref`/`.global_ref` → `frame.var_refs[idx]`（finalize 已定窗口，无生产越界返回）；`.global`/`.global_decl` → `createGlobalClosureVarRef`；module_decl/import → 扩容后取槽。
- **所有权 / 错误 / 调用**：留在捕获循环内，避免再加一层调用链。

### `attachFunctionCaptures` (`src/exec/object_ops.zig:434`)

- **签名**：`fn attachFunctionCaptures( ctx: *core.JSContext, global: *core.Object, fb: *const bytecode.FunctionBytecode, object: *core.Object, source: ClosureCaptureSource, ) HostError!void`。
- **作用**：在已挂 bytecode 的对象上分配捕获数组并填满（qjs 一次 `js_mallocz`，对象是唯一 GC 根）。
- **实现**：无闭包变量直接返回。`allocateNullCaptureSlots`；按 source 一次选源：nested 循环 `resolveNestedClosureCell`；root_global 先 `validateGlobalVarDeclarations` 再 `createRootGlobalClosureCell`；custom 同样先校验再 resolver。失败靠调用方对象 `errdefer` 走 `free_var_ref`（跳过仍为 null 的槽）。
- **所有权 / 错误 / 调用**：无 sidecar、无 per-slot initialized 计数。

### `createBytecodeFunctionObjectInternal` (`src/exec/object_ops.zig:470`)

- **签名**：`fn createBytecodeFunctionObjectInternal( ctx: *core.JSContext, global: *core.Object, value: core.JSValue, name_fallback: core.Atom, capture_source: ClosureCaptureSource, ) HostError!core.JSValue`。
- **作用**：`js_closure` 核心：校验 FB、分配函数对象、移入 bytecode、捕获、length/name。
- **实现**：root 住 `value`。须 function bytecode；Debug 断言 extension+code、realm==ctx 且 global 一致。`createWithOwnPropertyCapacity(..., 3)`。把 owned FB **移进** 对象（`rooted_value` 置 undefined）。`attachFunctionCaptures`。名字：`fb.func_name != empty_string` 用 func_name，否则 fallback。`jsFunctionSetProperties`。对照 `quickjs.c:17369-17417`：生产路径不重新校验已 finalize 的 FB。
- **所有权 / 错误 / 调用**：Pool.get/fclosure 交给本函数一份 owned FB。

### `jsFunctionSetProperties` (`src/exec/object_ops.zig:523`)

- **签名**：`fn jsFunctionSetProperties( rt: *core.JSRuntime, object: *core.Object, name_atom: core.Atom, length: i32, ) HostError!void`。
- **作用**：`js_function_set_properties`（`quickjs.c:5853-5861`）：可配置的 `length` 与 `name`。
- **实现**：`defineOwnDataValueAssumingNew` 两次。name 用 `toStringValueForPush`（dup atom 的字符串体；前缀/公开 Symbol 组合是 `JS_DefineObjectName`，不是这里）。
- **所有权 / 错误 / 调用**：新鲜函数，CreateProperty miss → add_property，无 Descriptor 往返。

### `installOrdinaryFunctionPrototype` (`src/exec/object_ops.zig:550`)

- **签名**：`fn installOrdinaryFunctionPrototype( ctx: *core.JSContext, global: *core.Object, value: core.JSValue, ) HostError!void`。
- **作用**：普通函数的 prototype 策略；class 构造器不走这里。
- **实现**：无 `hasPrototype` 则返回。normal → `defineFunctionPrototypeAutoInit`（惰性 `JS_AUTOINIT_ID_PROTOTYPE`，可写不可枚举不可配置）。其余 kind 一律新建对象当 `.prototype`（W=true/E=C=false）：generator / async_generator 各自挂 `%Generator.prototype%` / `%AsyncGenerator.prototype%`，async 挂 `%Object.prototype%`。
- **所有权 / 错误 / 调用**：可构造性是 FB `hasPrototype ∧ normal`，无对象位。

### `createBytecodeFunctionObject` (`src/exec/object_ops.zig:591`)

- **签名**：`pub fn createBytecodeFunctionObject( ctx: *core.JSContext, frame: *frame_mod.Frame, global: *core.Object, value: core.JSValue, ) HostError!core.JSValue`。
- **作用**：嵌套函数：从当前帧捕获。
- **实现**：internal + `nested_frame`，name fallback empty_string；再 `installOrdinaryFunctionPrototype`。
- **所有权 / 错误 / 调用**：`OP_fclosure`。

### `createClassBytecodeFunctionObject` (`src/exec/object_ops.zig:608`)

- **签名**：`fn createClassBytecodeFunctionObject( ctx: *core.JSContext, frame: *frame_mod.Frame, global: *core.Object, value: core.JSValue, class_name: core.Atom, ) HostError!core.JSValue`。
- **作用**：class 构造器：用 class 名当 name fallback，**不** 装普通 prototype（由 `defineClass` 显式做）。
- **实现**：internal + nested_frame + `class_name`。
- **所有权 / 错误 / 调用**：`defineClass`。

### `createRootBytecodeFunctionObject` (`src/exec/object_ops.zig:626`)

- **签名**：`pub fn createRootBytecodeFunctionObject( ctx: *core.JSContext, global: *core.Object, value: core.JSValue, capture_source: ClosureCaptureSource, ) HostError!core.JSValue`。
- **作用**：脚本/eval 根函数对象，同时是根帧的 `current_function`。
- **实现**：拒绝 `.nested_frame`。internal + 普通 prototype 策略。
- **所有权 / 错误 / 调用**：消费 canonical 根 FB。

### `constructPrimitiveWrapperWithPrototype` (`src/exec/object_ops.zig:647`)

- **签名**：`pub fn constructPrimitiveWrapperWithPrototype( rt: *core.JSRuntime, class_id: core.class.ClassId, prototype: ?*core.Object, primitive: core.JSValue, ) !core.JSValue`。
- **作用**：`new Number/Boolean/Symbol/...`：带指定原型的包装对象。
- **实现**：root 住 primitive；`Object.create`；`setOptionalValueSlot(objectDataSlot)`。
- **所有权 / 错误 / 调用**：GC 单测验证直接 symbol 在创建期间存活。

### `aggregateErrorConstructWithPrototype` (`src/exec/object_ops.zig:685`)

- **签名**：`pub fn aggregateErrorConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`AggregateError` 构造：message/cause/errors + 栈。
- **实现**：root 住 args 与 cause。create error 对象。无 own `name`（在每类原型上，`quickjs.c:41441`）。args[1] 非 undefined → Annex B ToString 当 message。args[2] 对象且有 `cause` → 定义 cause。`aggregateErrorsIterableToArray` 定义 `errors`。`captureErrorStack`。
- **所有权 / 错误 / 调用**：`class_init` 与 Error 构造器。

### `suppressedErrorConstructWithPrototype` (`src/exec/object_ops.zig:795`)

- **签名**：`pub fn suppressedErrorConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`SuppressedError(error, suppressed, message?)`。
- **实现**：root args。可选 message（第三参）。定义 `error` 与 `suppressed`（缺省 undefined）。`captureErrorStack`。
- **所有权 / 错误 / 调用**：explicit resource / `using`。

### `disposableStackConstructWithPrototype` (`src/exec/object_ops.zig:875`)

- **签名**：`pub fn disposableStackConstructWithPrototype( ctx: *core.JSContext, global: *core.Object, prototype: ?*core.Object, ) !core.JSValue`。
- **作用**：空 `DisposableStack` 实例。
- **实现**：`Object.create(disposable_stack, prototype)`；`global` 形参不被读取（`prototype` 已由调用方从 new.target 解出），保留是为了与其它 `*ConstructWithPrototype` 入口同形，函数头注释已写明。
- **所有权 / 错误 / 调用**：`class_init`。async 变体在 `promise_ops`。

### `errorConstructWithPrototype` (`src/exec/object_ops.zig:888`)

- **签名**：`pub fn errorConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, name: []const u8, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Error` / NativeError 构造：message + 可选 cause + 栈。
- **实现**：忽略 `name`（own name 在原型上，new.target 派生原型自带名字）。args[0] 非 undefined → message。args[1] 对象含 `cause` 则定义。`captureErrorStack`。
- **所有权 / 错误 / 调用**：与 AggregateError 相同的 root 形状。

### `createCallSiteObject` (`src/exec/object_ops.zig:981`)

- **签名**：`pub fn createCallSiteObject(ctx: *core.JSContext, global: *core.Object, entry: core.BacktraceFrame) !core.JSValue`。
- **作用**：V8 风格 CallSite 对象。
- **实现**：原型来自 `callSitePrototypeFromGlobal`。native 帧 filename=null、行列=0；否则 atom 名或 `"<anonymous>"`，行/列至少为 1。`setCallSiteMetadata`。
- **所有权 / 错误 / 调用**：`error_stack_ops` 准备 `BacktraceFrame`。

### `callSitePrototypeFromGlobal` (`src/exec/object_ops.zig:1002`)

- **签名**：`pub fn callSitePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：惰性 CallSite.prototype（六个 get* / isNative + toStringTag）。
- **实现**：缓存；create；**对象根**钉住半成品（trace 不把 Zig 局部当根）。逐个 `defineNativeDataMethodNamedWithNativeId`；tag `"CallSite"`；`storeRealmValue`。
- **所有权 / 错误 / 调用**：安装过程会分配，可能触发 GC。

### `defineDataPropertyByAtom` (`src/exec/object_ops.zig:1036`)

- **签名**：`pub fn defineDataPropertyByAtom( rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue, writable: bool, enumerable: bool, configurable: bool, ) !void`。
- **作用**：带完整属性标志的 data define。
- **实现**：`defineOwnProperty(Descriptor.data(...))`。
- **所有权 / 错误 / 调用**：Error 构造用。

### `regExpPrototypeMethodIsDefault` (`src/exec/object_ops.zig:1048`)

- **签名**：`pub fn regExpPrototypeMethodIsDefault(_: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, expected_id: u32) bool`。
- **作用**：RegExp 实例的某方法是否仍是原型上的默认 native（不跑用户代码）。
- **实现**：class 须 regexp；own 已有该键 → 假；原型无 exotic；`findProperty`（shape 哈希，不是线性扫，对齐 `find_property_regexp`）。accessor → 假；data → `regExpNativeBuiltinMatches`；auto_init → `regExpAutoInitBuiltinMatches`。
- **所有权 / 错误 / 调用**：标准 regexp 快路径的 `exec` 检查。

### `regExpPrototypeGetterIsDefault` (`src/exec/object_ops.zig:1073`)

- **签名**：`pub fn regExpPrototypeGetterIsDefault(_: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, expected_id: u32) bool`。
- **作用**：标志 getter（flags/global/unicode/sticky）是否默认 native accessor。**绝不调用 getter**。
- **实现**：同 method 检查，但只要 `.accessor` 且 getter 匹配 native id。对齐 qjs `check_regexp_getter`。
- **所有权 / 错误 / 调用**：`Symbol.replace/get-*-err` 要求覆盖 getter 走泛化路径并按 spec 顺序观察。

### `regExpIsStandard` (`src/exec/object_ops.zig:1093`)

- **签名**：`pub fn regExpIsStandard(rt: *core.JSRuntime, object: *core.Object) bool`。
- **作用**：`js_is_standard_regexp`：真 RegExp、`lastIndex` 是 number、exec 与 flags/global/unicode 都是原装内建。
- **实现**：class；`regexpLastIndex()` 必须存在且 `isNumber()`（非 number 要走 ToLength）；再四个默认检查。
- **所有权 / 错误 / 调用**：真才允许从编译字节码读 flags，跳过可观察属性读。

### `setValuePropertyStrict` (`src/exec/object_ops.zig:1112`)

- **签名**：`pub fn setValuePropertyStrict( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：严格 `[[Set]]`：失败一律 TypeError/RangeError。`Object.assign` 用。
- **实现**：expectObject。Proxy → `proxySetValueProperty`，假则 TypeError。`arrayLengthAssignmentValue`。TypedArray canonical set。先 `setOwnWritableDataProperty`（qjs 第一次 `find_own_property`，含 RegExp `lastIndex`）。再 `callAccessorSetter`（无 setter → TypeError）。最后 `setProperty`，只读/不可扩展 → TypeError，InvalidLength → RangeError。
- **所有权 / 错误 / 调用**：比 `setValueProperty` 更硬：不考虑宽松模式吞失败。

### `regExpPrototypeFromGlobal` (`src/exec/object_ops.zig:1148`)

- **签名**：`pub fn regExpPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?OwnedPrototype`。
- **作用**：从全局 RegExp 构造器取 `.prototype` handle。
- **实现**：`regExpConstructorFromGlobal`；own data `prototype`。
- **所有权 / 错误 / 调用**：失败 `null`。

### `datePrototypeMethod` (`src/exec/object_ops.zig:1155`)

- **签名**：`pub fn datePrototypeMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Date.prototype 方法的 exec 入口：少数 id 特判，其余进 `.date` record。
- **实现**：id 11 `dateToJsonCall`；23 `dateSetYear`；24 `dateSetTime`；再 `dateCapturedSetterCall`。其余 `callInternalRecord`，TypeError 收成 `"not a Date object"`，RangeError 收成 `"Date value is NaN"`。
- **所有权 / 错误 / 调用**：不把 Date 方法体编进本文件。

### `defineFreshNonIndexDataProperty` (`src/exec/object_ops.zig:1190`)

- **签名**：`pub fn defineFreshNonIndexDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, writable: bool, enumerable: bool, configurable: bool) !void`。
- **作用**：假定键是新的非下标属性，走 `defineOwnNonIndexPropertyAssumingNew`。
- **实现**：一层转调。
- **所有权 / 错误 / 调用**：RegExp `groups` 等新鲜结果对象。

### `defineRegExpIndicesGroupsProperty` (`src/exec/object_ops.zig:1194`)

- **签名**：`pub fn defineRegExpIndicesGroupsProperty(rt: *core.JSRuntime, global: *core.Object, out: *core.Object, found: *const RegExpMatch) !void`。
- **作用**：给 `/d` 结果对象装 `groups`：无命名捕获则 undefined；有则新建对象，值为 `[start, end]` 对。
- **实现**：逐捕获：无名字 skip；解码组名 intern；atom 根（TGC S3 §4 B）；重复名：未匹配的 duplicate 不得覆盖已匹配。`createRegExpIndexPair`。
- **所有权 / 错误 / 调用**：`groups` 对象先 raw owned，define 成功后交给 `out`。

### `populateRegExpGroupsFromCaptureValues` (`src/exec/object_ops.zig:1236`)

- **签名**：`pub noinline fn populateRegExpGroupsFromCaptureValues( rt: *core.JSRuntime, groups: *core.Object, found: *const RegExpMatch, capture_values: []const core.JSValue, ) !void`。
- **作用**：用 exec 结果里已经切好的捕获字符串填命名 `groups`，不再二次切片输入。
- **实现**：断言 `has_named_captures` 且 `capture_values.len >= capture_count+1`（下标 0 是整次匹配）。逐捕获：无名字 skip；`appendDecodedRegExpGroupName` 后 intern；atom 根（TGC S3 §4 B）。重复名：未匹配的 duplicate 若该键已存在则 continue，不得覆盖已匹配项。值取 `capture_values[capture_index+1]`，W/E/C=true。对照 qjs `js_regexp_exec` 同一捕获循环同时填稠密结果与 `groups`；本助手拆出是为了让公共结果构造体保持紧凑，所有权模型不变。
- **所有权 / 错误 / 调用**：`string_ops` 在 dense cell 填完捕获后、`adoptDenseArrayElementsAssumingEmpty` 前。`groups` 由调用方创建并最终挂到结果对象。值是 cell 里已有的 JSValue 再 define（非再 slice）。

### `primitivePrototypeMethod` (`src/exec/object_ops.zig:1265`)

- **签名**：`pub fn primitivePrototypeMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, this_value: core.JSValue, id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Boolean/Number/BigInt/Symbol/String 原型方法的打包分发（id = class_tag*10 + method_tag）。
- **实现**：method 3：Boolean 当函数 `Boolean(x)`；Symbol 当函数 `symbolConstructorCall`。method 4/5：Symbol `description` / `@@toPrimitive`。其它先 `primitivePrototypeThisValue` 校验 this。method 1：Number → number record `toString`；BigInt → `bigIntPrototypeToString`；否则 `toStringValue`。method 2：valueOf，返回 primitive。
- **所有权 / 错误 / 调用**：校验失败 `throwPrimitivePrototypeTypeError`（用函数对象的 realm）。

### `symbolConstructorCall` (`src/exec/object_ops.zig:1328`)

- **签名**：`fn symbolConstructorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`Symbol(desc)` 当函数，永不构造。
- **实现**：有参且非 undefined：若已是 symbol → `"cannot convert symbol to string"`；Annex B ToString，`appendRawString` 成 owned 字节。`rt.newSymbolValue`。
- **所有权 / 错误 / 调用**：description 缓冲 defer free。

### `symbolDescriptionValue` (`src/exec/object_ops.zig:1352`)

- **签名**：`fn symbolDescriptionValue(rt: *core.JSRuntime, this_value: core.JSValue) !core.JSValue`。
- **作用**：`Symbol.prototype.description`。
- **实现**：`symbolPrimitiveValue`；`core.symbol.description` 无则 undefined，有则字符串。
- **所有权 / 错误 / 调用**：非 symbol TypeError。

### `symbolPrimitiveValue` (`src/exec/object_ops.zig:1361`)

- **签名**：`fn symbolPrimitiveValue(_: *core.JSRuntime, this_value: core.JSValue) !core.JSValue`。
- **作用**：`@@toPrimitive`：解包装得到 symbol 原始值。
- **实现**：已是 symbol 原样；否则须 symbol class 且 `objectData()` 为 symbol。
- **所有权 / 错误 / 调用**：忽略 rt。

### `throwPrimitivePrototypeTypeError` (`src/exec/object_ops.zig:1374`)

- **签名**：`pub fn throwPrimitivePrototypeTypeError( ctx: *core.JSContext, global: *core.Object, function_object: *core.Object, class_tag: i32, ) !core.JSValue`。
- **作用**：原型方法 this 不对时，用 **函数对象的 realm** 造 TypeError。
- **实现**：`objectRealmGlobal(function_object) orelse global`。消息：not a boolean/bigint/symbol/string。`createNamedError` + `throwValue` → `error.JSException`。
- **所有权 / 错误 / 调用**：跨 realm 调用时错误构造器必须来自 callee。

### `getNumberPrototypeMethodId` (`src/exec/object_ops.zig:1393`)

- **签名**：`pub fn getNumberPrototypeMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?u32`。
- **作用**：若函数是 Number.prototype 的 toString/toLocaleString/toFixed/toExponential/toPrecision，返回其 native id。
- **实现**：decode builtin；domain 须 `.number`。`rt` 形参不被读取，保留是为了与同族 `get*PrototypeMethodId` 探针同形，函数头注释已写明。
- **所有权 / 错误 / 调用**：快调识别。

### `numberPrototypeMethod` (`src/exec/object_ops.zig:1410`)

- **签名**：`pub fn numberPrototypeMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：把历史小 id 1..5 与 `PrototypeMethod` 枚举都路由到 `.number` record。
- **实现**：switch 归一化 id；`callInternalRecord`；失败 `"not a number"`。
- **所有权 / 错误 / 调用**：record 自己做 receiver 强制。

### `primitivePrototypeThisValue` (`src/exec/object_ops.zig:1439`)

- **签名**：`pub fn primitivePrototypeThisValue(rt: *core.JSRuntime, value: core.JSValue, class_tag: i32) !core.JSValue`。
- **作用**：校验 this 是对应原始值或包装，返回内部原始值。
- **实现**：tag 1..5 分别 number/bool/bigint/symbol/string。对象须 class 匹配，然后 `objectData()`（原先 `class_tag == 5` 与其余两条同构分支已折成一句）。`rt` 形参不被读取，保留是因为两个调用点都按同样方式往下传，函数头注释已写明。
- **所有权 / 错误 / 调用**：失败 TypeError，由调用方换成带消息版本。

### `defineErrorStackDataProperty` (`src/exec/object_ops.zig:1462`)

- **签名**：`pub fn defineErrorStackDataProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, stack_key: core.Atom, desc: core.Descriptor, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：给 Error 定义 `stack` 数据/访问器，尊重 Proxy。
- **实现**：Proxy → `proxyDefineOwnProperty`，假则 TypeError。否则 `defineOwnProperty`，只读/不可扩展/不兼容 → TypeError，InvalidLength → RangeError。
- **所有权 / 错误 / 调用**：`error_stack_ops`。

### `dataViewConstructWithPrototype` (`src/exec/object_ops.zig:1484`)

- **签名**：`pub fn dataViewConstructWithPrototype( rt: *core.JSRuntime, buffer: core.JSValue, coerced: DataViewConstructorArgs, prototype: ?*core.Object, ) !core.JSValue`。
- **作用**：把已强制的 offset/length 收成 `dataViewConstruct` 参数。
- **实现**：按 `has_offset` / `view_length` 切 1/2/3 个参数。
- **所有权 / 错误 / 调用**：`class_init` 在 `dataViewConstructorArgs` 之后。

### `defineClassFieldDataProperty` (`src/exec/object_ops.zig:1502`)

- **签名**：`pub fn defineClassFieldDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void`。
- **作用**：实例字段（含私有）定义。私有重复 → TypeError。
- **实现**：private 且已有 own → TypeError。`defineOwnProperty` data W/E/C=true。不兼容/不可扩展/只读 → TypeError。
- **所有权 / 错误 / 调用**：NO-ALIGN(qjs)：`JS_DefinePrivateField`（`quickjs.c:8374`）忽略可扩展性；test262 `nonextensible-applies-to-private` 要求 TypeError，zjs 跟 spec。

### `constructWeakRefWithPrototype` (`src/exec/object_ops.zig:1517`)

- **签名**：`pub fn constructWeakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：带原型的 WeakRef。
- **实现**：`construct_mod.weakRefWithPrototype`。
- **所有权 / 错误 / 调用**：目标弱可达性由调用方检查。

### `constructFinalizationRegistryWithPrototype` (`src/exec/object_ops.zig:1521`)

- **签名**：`pub fn constructFinalizationRegistryWithPrototype( ctx: *core.JSContext, cleanup_callback: core.JSValue, prototype: ?*core.Object, ) !core.JSValue`。
- **作用**：创建 registry 并写入 cleanup 回调槽。
- **实现**：root 住 callback；`createFinalizationRegistry`；`setOptionalValueSlot(finalizationRegistryCleanupCallbackSlot)`。
- **所有权 / 错误 / 调用**：callback 必须在 create 期间保持活。

### `constructCollectionWithPrototypeFromVm` (`src/exec/object_ops.zig:1543`)

- **签名**：`pub fn constructCollectionWithPrototypeFromVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, kind: u32, args: []const core.JSValue, prototype: ?*core.Object, ) !core.JSValue`。
- **作用**：Map/Set/WeakMap/WeakSet：空实例走 collection construct record，有 iterable 则 adder 协议填充。
- **实现**：`constructIdForKind`；`callConstructRecord` 无参。无 iterable 返回。Get `set` 或 `add`；不可调用 TypeError。`addCollectionEntriesFromIterator`（是否走稠密数组由 iterator 路径在确认 `@@iterator` 未被篡改后决定，与 `[...src]` 相同守卫）。
- **所有权 / 错误 / 调用**：构造器对象无 native id，用显式 ref。

### `OwnedPrototype.fromObject` (`src/exec/object_ops.zig:1587`)

- **签名**：`pub fn fromObject(prototype: ?*core.Object) OwnedPrototype`。
- **作用**：从可选对象造 handle；null 变成 JS null。
- **实现**：`{ .value = prototype.value() or nullValue() }`。
- **所有权 / 错误 / 调用**：无额外 retain；调用方负责 `deinit` 前的存活。

### `OwnedPrototype.object` (`src/exec/object_ops.zig:1591`)

- **签名**：`pub fn object(self: OwnedPrototype) ?*core.Object`。
- **作用**：把 handle 收成对象指针。
- **实现**：`objectFromValue(self.value)`。
- **所有权 / 错误 / 调用**：null 原型返回 `null`。

### `OwnedPrototype.deinit` (`src/exec/object_ops.zig:1595`)

- **签名**：`pub fn deinit(self: *OwnedPrototype, _: *core.JSRuntime) void`。
- **作用**：放下 handle（tracer 下只需丢掉根）。
- **实现**：`self.value = undefinedValue()`。忽略 rt。
- **所有权 / 错误 / 调用**：须在新对象已保留原型之后。

### `constructorPrototypeObject` (`src/exec/object_ops.zig:1600`)

- **签名**：`pub fn constructorPrototypeObject(rt: *core.JSRuntime, constructor: core.JSValue) !OwnedPrototype`。
- **作用**：不经 VM/Proxy 分发的 `constructor.prototype`：own data 优先，否则 `property_ops.getPropertyValue`。
- **实现**：非对象 → null handle。own data 对象命中即返回。Get 结果是对象则转移进 handle，否则 null。
- **所有权 / 错误 / 调用**：会跑 getter。GetPrototypeFromConstructor 的 VM 版是 `reflectConstructPrototypeVm`。

### `dynamicFunctionNewTargetPrototype` (`src/exec/object_ops.zig:1610`)

- **签名**：`pub fn dynamicFunctionNewTargetPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, new_target: core.JSValue, kind: DynamicFunctionKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !OwnedPrototype`。
- **作用**：`new Function` 等：Get `new_target.prototype`，非对象则用 new_target 的 realm intrinsic。
- **实现**：Get 是对象 → handle。否则 `functionRealmContext` + 按 DynamicFunctionKind 选 class 原型。
- **所有权 / 错误 / 调用**：`InvalidBuiltinRegistry` 若 realm 未装表。

### `constructorClassPrototypeId` (`src/exec/object_ops.zig:1635`)

- **签名**：`pub fn constructorClassPrototypeId(name: []const u8) ?core.ClassId`。
- **作用**：qjs `js_create_from_ctor(..., class_id)` 的名字表。NativeError **不在** 此表（走 `native_error_proto[]`）。
- **实现**：Object/Function/Array/…/Iterator + TypedArray 元素 kind → 对应 class。
- **所有权 / 错误 / 调用**：`reflectConstructPrototypeVm` 回退。

### `nativeErrorKindFromConstructorName` (`src/exec/object_ops.zig:1681`)

- **签名**：`pub fn nativeErrorKindFromConstructorName(name: []const u8) ?core.context.NativeErrorKind`。
- **作用**：Error 子类名 → realm `native_error_proto` 槽。
- **实现**：Error/EvalError/…/SuppressedError。
- **所有权 / 错误 / 调用**：与 `constructorClassPrototypeId` 互补。

### `objectRealmGlobal` (`src/exec/object_ops.zig:1695`)

- **签名**：`pub fn objectRealmGlobal(object: *core.Object) ?*core.Object`。
- **作用**：FunctionRealm：递归解开 Proxy 与 bound function。
- **实现**：proxy target 递归；bound 解 target；generator/async_generator 的 realm global 指针；bytecode/native function 指针；最后 `functionRealmGlobal` 值。对照 `JS_GetFunctionRealm`。**调用分发**不走这条：包装保持 caller view 直到最终 bytecode/C 臂。
- **所有权 / 错误 / 调用**：错误对象跨 realm 时选构造器。

### `propertyIndexFromLengthKey` (`src/exec/object_ops.zig:1718`)

- **签名**：`pub fn propertyIndexFromLengthKey(rt: *core.JSRuntime, atom_id: core.Atom) ?usize`。
- **作用**：把属性键当成数组下标：int atom 或纯数字字符串。
- **实现**：`arrayIndexFromAtom`；否则 string 名须全是 `'0'..'9'`，`parseUnsigned`。
- **所有权 / 错误 / 调用**：空串 `null`。

### `propertyAtomFromLengthIndex` (`src/exec/object_ops.zig:1729`)

- **签名**：`pub fn propertyAtomFromLengthIndex(rt: *core.JSRuntime, index: usize) !LengthIndexAtom`。
- **作用**：下标 → atom；大下标 intern 并 `pinForHost`。
- **实现**：`index <= max_int_atom` → tagged int，`owned=false`。否则 allocPrint intern，`owned=true`（TGC S3 §2.2，须 `deinit`）。
- **所有权 / 错误 / 调用**：Proxy ownKeys 循环里 defer deinit。

### `createDataPropertyOrThrow` (`src/exec/object_ops.zig:1739`)

- **签名**：`pub fn createDataPropertyOrThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, object: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：CreateDataPropertyOrThrow：Proxy 走 trap，否则数组/TypedArray 元素或普通 define。
- **实现**：有 proxy target → `proxyCreateDataPropertyOrThrow`（不再转发 receiver）。否则 `createArrayDataOrTypedArrayElement`。`receiver_value` 形参不被读取（CreateDataProperty 无 receiver），保留是因为 VM / Object.* 调用点手上已有装箱的 `object`。
- **所有权 / 错误 / 调用**：fromEntries、groupBy、enumerable own properties。

## 覆盖核对

- 清单函数数（本文件分到）: 67（`src/exec/object_ops.zig` 全文件 194）
- 本文标题覆盖: 67
- 未覆盖: 其余见 [14-object-ops-objects.md](14-object-ops-objects.md)、[14-object-ops-get-set.md](14-object-ops-get-set.md)、[14-object-ops-proxy.md](14-object-ops-proxy.md)
