# 07 — AUTOINIT（`src/core/object.zig`）

AUTOINIT 用 placeholder 延迟创建标准库属性、函数 prototype 或 module namespace 绑定。槽保存 realm 追踪边，以及 intern 过的 property.AutoInit 或 module owner；本文件的部分描述符/读入口会触发物化，并非只有完整 JS [[Get]] 才会触发。

materializeAutoInit 先准备唯一 Shape，核对原槽，调用 builder，再核对并提交。非全局 value 提交直接改 data；全局 value 提交还要分配 VarRef cell，可能失败。失败不代表整个过程回滚：Shape 准备与 builder 副作用可以保留，重入也可能已改变原槽。RealmRef 是追踪指针，不能按旧 RC 注释理解成增减 realm 引用计数。

---


### `Object.materializeAutoInit` (`src/core/object.zig:7781`)

- **签名**：`fn materializeAutoInit(self: *Object, index: usize) PropertyReadError!JSValue`。
- **作用**：校验并构建一个延迟属性，再提交为 data 或 VarRef。
- **实现**：检查 index/auto-init，保存 atom 与 slot，取保存的 realm/runtime；先 ensureUniqueShapeForMutation 并复核槽，再按 prototype/module_ns/prop 执行 builder。返回 value 时再次复核并 commitAutoInitValue；返回 VarRef 仅允许 module_ns，复核后 commitAutoInitVarRef。
- **所有权 / 错误 / 调用**：形状准备或 builder 失败不会由本函数提交新槽，但可能已克隆 shape 或产生 builder 副作用；重入改变原槽会被复核拒绝。global 的 value 提交还要分配 closed VarRef，因此不能把整个 commit 描述为绝不失败。realm 来源是 placeholder 保存的 construction realm。

### `Object.materializeModuleAutoInit` (`src/core/object.zig:7819`)

- **签名**：`fn materializeModuleAutoInit( realm: *context_mod.RealmContext, owner: *const property.AutoInitModuleOwner, atom_id: atom.Atom, ) PropertyReadError!property.AutoInitMaterialization`。
- **作用**：调用模块 placeholder 的解析回调。
- **实现**：owner.resolve(owner,&realm.header,atom_id)，错误通过 @errorCast 转入 PropertyReadError。
- **所有权 / 错误 / 调用**：不自行加载模块、缓存结果或提交槽；回调返回 value/var_ref materialization。

### `Object.autoInitSlotStillMatches` (`src/core/object.zig:7827`)

- **签名**：`fn autoInitSlotStillMatches(self: *const Object, index: usize, expected_atom: atom.Atom, expected: property.AutoInitSlot) bool`。
- **作用**：核对延迟属性仍是预期的同一占位槽。
- **实现**：检查 index 范围、atom 相同、仍为 auto-init，再比较 realm_and_id.raw 与 opaque_ptr。
- **所有权 / 错误 / 调用**：不比较 writable/enumerable/configurable，也不验证 builder 返回值；用于提交前检测重入变更。

### `Object.commitAutoInitValue` (`src/core/object.zig:7834`)

- **签名**：`fn commitAutoInitValue(self: *Object, rt: *JSRuntime, index: usize, materialized: JSValue) !JSValue`。
- **作用**：把构建出的值安装为普通 data 或 global VarRef 属性。
- **实现**：保存旧 flags；非 global 直接写 data、屏障值、将 flags.kind 更新为 data 后返回。global 先 createClosed(materialized)，设置非 lexical、const=!writable、deletable=configurable，再写 var_ref、屏障 cell、更新 kind 并返回 cell 值。
- **所有权 / 错误 / 调用**：global 的 cell 创建可失败，失败前不覆盖原槽；其他描述符位保留。调用方须已准备可变 Shape 并重新验证 placeholder。本函数不再复核 atom/slot，也不做 RC 释放。

### `Object.commitAutoInitVarRef` (`src/core/object.zig:7862`)

- **签名**：`fn commitAutoInitVarRef(self: *Object, rt: *JSRuntime, index: usize, cell: *var_ref_mod.VarRef) JSValue`。
- **作用**：提交 module resolver 给出的 VarRef cell。
- **实现**：保存旧 flags，写 var_ref、屏障 cell、更新 flags.kind，返回 cell.varRefValue。
- **所有权 / 错误 / 调用**：不分配、不设置 cell 的 const/deletable/lexical 标志，也不在此对 uninitialized 值抛 TDZ；调用方负责 resolver 和槽一致性。

### `Object.materializeAutoInitEntryForMutation` (`src/core/object.zig:7870`)

- **签名**：`fn materializeAutoInitEntryForMutation(self: *Object, index: usize) !void`。
- **作用**：在修改前按需物化 auto-init 属性。
- **实现**：index 越界 IncompatibleDescriptor；非 auto-init 直接返回；校验 realm header 非空，然后调用 materializeAutoInit 并忽略返回值。
- **所有权 / 错误 / 调用**：物化或验证错误传播，不把失败 placeholder 改成 undefined；即便最终不使用构建值也可能分配或执行回调。

### `Object.materializePropAutoInit` (`src/core/object.zig:7884`)

- **签名**：`fn materializePropAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) PropertyReadError!JSValue`。
- **作用**：按 AutoInit 描述信息选择属性构造器。
- **实现**：依次分派 console、math/json/reflect/atomics namespace、navigator、performance、array_unscopables、string_constant、empty_array；其余 host_function_kind 非零走 host function，否则 native function。
- **所有权 / 错误 / 调用**：只负责 builder 分派与错误传播，不提交目标属性槽；专门 kind 优先于 host_function_kind。

### `Object.materializeStringConstantAutoInit` (`src/core/object.zig:7902`)

- **签名**：`fn materializeStringConstantAutoInit(rt: *JSRuntime, info: *const property.AutoInit) !JSValue`。
- **作用**：构造描述信息 name 对应的字符串值。
- **实现**：name 为空复用 rt.emptyString，否则 String.createAscii(rt,info.name)，返回 value。
- **所有权 / 错误 / 调用**：不是一般 ToString；createAscii 的输入合同由描述信息保证，分配/缓存错误传播。

### `Object.materializeEmptyArrayAutoInit` (`src/core/object.zig:7911`)

- **签名**：`fn materializeEmptyArrayAutoInit(realm: *context_mod.RealmContext) !JSValue`。
- **作用**：用 construction realm 的 Array prototype 创建空 Array。
- **实现**：先 arrayPrototypeValueForAutoInit(realm)，再 objectFromValue 原型并 Object.createArray，返回值。
- **所有权 / 错误 / 调用**：不安装到 placeholder；原型解析与对象分配错误传播，不填充元素。

### `Object.materializeNativeFunctionAutoInit` (`src/core/object.zig:7917`)

- **签名**：`fn materializeNativeFunctionAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) !JSValue`。
- **作用**：在 construction realm 内构建带预留属性容量的 native 函数。
- **实现**：cached_function_proto 缺失 InvalidBuiltinRegistry；用 name/length/capacity=2 构造。编译期开启 value_root_frames_enabled 时将值置于 rootValues 帧后 prepareAutoInitNativeFunction，否则直接 prepare；成功返回函数值。
- **所有权 / 错误 / 调用**：不是无条件启用显式根帧；构造/prepare 可失败，不在此提交属性。函数原型与 realm 由构造步骤安装。

### `Object.prepareAutoInitNativeFunction` (`src/core/object.zig:7932`)

- **签名**：`fn prepareAutoInitNativeFunction( rt: *JSRuntime, info: *const property.AutoInit, function_value: JSValue, ) PropertyReadError!void`。
- **作用**：为新 native 函数安装 builtin id、功能 marker 并执行可选准备回调。
- **实现**：native_builtin_id 非零且 refHeader 存在时转 Object 并 setNativeBuiltinIdAndRecord；随后 applyAutoInitFunctionMarkers，再调用可选 prepare_native_function 并转换错误。
- **所有权 / 错误 / 调用**：假定输入是适合的函数对象，refHeader 分支不额外验证 Object kind。失败不回滚先前 id/marker 或回调副作用；目标 placeholder 的提交由外层控制。

### `Object.materializeArrayUnscopablesAutoInit` (`src/core/object.zig:7951`)

- **签名**：`fn materializeArrayUnscopablesAutoInit(rt: *JSRuntime) !JSValue`。
- **作用**：创建 null 原型的 Array unscopables 对象。
- **实现**：依次安装 at、copyWithin、entries、fill、find、findIndex、findLast、findLastIndex、flat、flatMap、includes、keys、toReversed、toSorted、toSpliced、values，值均 true，描述符 w/e/c 均 true。每个名称 intern 后用 atom root 帧覆盖 define 分配窗口。
- **所有权 / 错误 / 调用**：构建失败传播，不安装目标 placeholder；已完成的局部对象属性不逐一回滚。只保护此处明确列出的 atom 根，不能描述为此函数显式 root 了全部对象值。

### `Object.applyAutoInitFunctionMarkers` (`src/core/object.zig:7988`)

- **签名**：`fn applyAutoInitFunctionMarkers(rt: *JSRuntime, function_value: JSValue, info: *const property.AutoInit) !void`。
- **作用**：把描述信息中的非空功能标记应用到函数 rare payload。
- **实现**：检查 array/typed-array marker、iterator kind/identity、collection owner、同步/异步 disposal method；全空立即返回。否则 Object.expect、ensure rare payload，再按顺序用 set helpers 设置非空项，冲突 InvalidBuiltinRegistry；全部通过后才设置 iterator_identity。
- **所有权 / 错误 / 调用**：or 条件短路，前面成功写入的标记在后面冲突时不回滚。无标记时不验证 function_value 类型；不是复制 AutoInit 所有字段。

### `Object.materializeHostFunctionAutoInit` (`src/core/object.zig:8011`)

- **签名**：`fn materializeHostFunctionAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) !JSValue`。
- **作用**：构造带 host kind 和可选 prototype 的 native 函数。
- **实现**：要求 realm.global 与 cached_function_proto；按是否需要 prototype 预留 2 或 3 个属性，创建函数并写 host_function_kind，可选 installNativeEntry。需要 prototype 时取得 Object prototype，创建空普通对象并把函数的 prototype 属性定义为 w/e/c 均 true。
- **所有权 / 错误 / 调用**：不自动创建 prototype.constructor 回边，也不调用 applyAutoInitFunctionMarkers 或 prepare_native_function；分配/定义错误传播，未提交 placeholder。

### `Object.materializeBuiltinNamespaceAutoInit` (`src/core/object.zig:8031`)

- **签名**：`fn materializeBuiltinNamespaceAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) PropertyReadError!JSValue`。
- **作用**：通过 runtime 回调构造内置 namespace。
- **实现**：要求 realm.global 和 materialize_builtin_namespace_cb，调用 cb(runtime,global,info.kind)，转换回调错误；回调返回 null 则 InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：不在此定义 namespace 成员或验证返回值类型，实际构造由回调决定。

### `Object.defineHostAutoInitDataPropertyByName` (`src/core/object.zig:8038`)

- **签名**：`fn defineHostAutoInitDataPropertyByName( rt: *JSRuntime, target: *Object, name: []const u8, length: i32, host_function_kind: i32, entry: ?*const native_entry.NativeEntry, realm_global: ?*Object, ) !void`。
- **作用**：按字符串名称安装 host-function 延迟属性。
- **实现**：internAtom(name)，激活 atom root 帧，调用 defineHostAutoInitPropertyWithEntry，传 w/e/c 均 true、host kind、host_function_prototype=false、realm_global 和 entry。
- **所有权 / 错误 / 调用**：这里只安装 placeholder，不立即构造函数；intern/define 错误传播，atom 根帧在返回时撤销。

### `Object.materializeConsoleAutoInit` (`src/core/object.zig:8065`)

- **签名**：`fn materializeConsoleAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) !JSValue`。
- **作用**：构造含三个延迟方法的 console 对象。
- **实现**：host_function_kind 为零或 realm.global 缺失则 InvalidBuiltinRegistry；取 Object prototype，创建容量 3 的普通对象；依次安装 log/warn/error，length=1，复用 info 的 host kind/native entry 与 construction global。
- **所有权 / 错误 / 调用**：方法仍是 auto-init 属性，w/e/c 均 true；不输出日志。构建失败不提交 console placeholder。

### `Object.materializeNavigatorAutoInit` (`src/core/object.zig:8079`)

- **签名**：`fn materializeNavigatorAutoInit(realm: *context_mod.RealmContext) !JSValue`。
- **作用**：构造带专用原型的 navigator 对象。
- **实现**：先创建继承 Object prototype、容量 2 的原型；安装 Symbol.toStringTag="Navigator"（只 configurable），创建名为 get userAgent、length 0 的 native getter并设置 host builtin id；定义可枚举可配置 userAgent accessor，setter undefined。最后创建继承该原型的空对象。
- **所有权 / 错误 / 调用**：userAgent 与 tag 属于原型，不是 navigator 自有属性；此处不调用 getter。创建/定义失败传播。

### `Object.materializePerformanceAutoInit` (`src/core/object.zig:8108`)

- **签名**：`fn materializePerformanceAutoInit(realm: *context_mod.RealmContext) !JSValue`。
- **作用**：构造 performance 对象与 now/timeOrigin 属性。
- **实现**：要求 realm.global；runtime.performance_time_origin_ms 为零时先取时间写入。创建继承 Object prototype、容量 2 的对象，安装延迟 now（length 0、performance builtin id 1、可写不可枚举可配置）及 timeOrigin 数据值（w/e/c 均 true）。
- **所有权 / 错误 / 调用**：time origin 是 runtime 共用字段，初始化发生在后续可能失败的分配之前，失败不回滚它。now 此时尚未物化；timeOrigin 为安装时的数值副本。

### `Object.performanceAutoInitNowMs` (`src/core/object.zig:8138`)

- **签名**：`fn performanceAutoInitNowMs() f64`。
- **作用**：读取 awake 时钟并转换为毫秒浮点数。
- **实现**：使用 Threaded.global_single_threaded.io，Clock.Timestamp.now(io,.awake).raw.toNanoseconds，再转换 f64 并除 ns_per_ms。
- **所有权 / 错误 / 调用**：不是此函数计算的 Unix wall-clock 时间或相对 timeOrigin 差值；不返回错误。

### `Object.objectPrototypeValueForAutoInit` (`src/core/object.zig:8151`)

- **签名**：`fn objectPrototypeValueForAutoInit(realm: *context_mod.RealmContext) !JSValue`。
- **作用**：取得 construction realm 的 Object prototype 值。
- **实现**：要求 realm.global；cached object_prototype 为 Object 值则直接返回。否则普通 getProperty 读取 global.Object，非 Object 则 InvalidBuiltinRegistry；再读其 prototype，Object 值返回，否则 JS null。
- **所有权 / 错误 / 调用**：当前无 RC dup/free；getProperty 会物化 auto-init，但 accessor 路径返回 getter 本身，不应把此回退描述为完整规范 Get。函数返回值并不独立建立 GC 根。

### `Object.materializeFunctionPrototypeAutoInit` (`src/core/object.zig:8171`)

- **签名**：`fn materializeFunctionPrototypeAutoInit(self: *Object, realm: *context_mod.RealmContext) !JSValue`。
- **作用**：构造延迟 function.prototype 对象及 constructor 回边。
- **实现**：用 construction realm 的 Object prototype 创建普通对象，注册失败清理；定义 constructor=self.value，writable/configurable true、enumerable false；成功撤销局部清理责任并返回 prototype 值。
- **所有权 / 错误 / 调用**：定义失败直接 destroyFromHeader 新建 prototype；不提交 self 的 auto-init 槽，提交由外层完成。

### `Object.defineFunctionPrototypeAutoInit` (`src/core/object.zig:8192`)

- **签名**：`pub fn defineFunctionPrototypeAutoInit( self: *Object, rt: *JSRuntime, realm: *context_mod.RealmContext, flags: property.Flags, ) !void`。
- **作用**：在新函数上安装 prototype 延迟槽。
- **实现**：断言无 exotic methods 且 extensible，AutoInitSlot.retainPrototype 保存 realm header，再用 appendPreparedPropertyEntryImpl(true,true) 追加 prototype，保留 flags 其他位并改 kind 为 auto_init。
- **所有权 / 错误 / 调用**：不执行重复属性探测；新属性、合适 flags 及 realm 生命周期由调用方保证。两个 true 分别承诺 atom 独立保活和非索引 named-put 路径，不代表全流程不会分配失败。

### `Object.arrayPrototypeValueForAutoInit` (`src/core/object.zig:8239`)

- **签名**：`fn arrayPrototypeValueForAutoInit(realm: *context_mod.RealmContext) !JSValue`。
- **作用**：取得 construction realm 的 Array prototype 值。
- **实现**：要求 realm.global；cached array_prototype 为 Object 则返回。否则取得预定义 Array atom，普通 getProperty 读 constructor，非 Object 报 InvalidBuiltinRegistry；再读 prototype，Object 返回，其他返回 JS null。
- **所有权 / 错误 / 调用**：不执行完整 Proxy/accessor Get；沿用普通 getProperty 的物化与错误行为，无 RC dup 或额外根。

### `Object.autoInitRealmForDefinition` (`src/core/object.zig:8507`)

- **签名**：`fn autoInitRealmForDefinition(self: *Object, rt: *JSRuntime, explicit_global: ?*Object) !*context_mod.RealmContext`。
- **作用**：按显式 global 或 receiver 所属上下文解析 construction realm。
- **实现**：显式 global 非空时仅 contextForGlobalIncludingConstructing 查询，缺失立即 InvalidBuiltinRegistry；否则依次 bytecode realm、native realm、receiver 作为 global 的 context，全部失败报同错。
- **所有权 / 错误 / 调用**：不回退到任意当前调用 realm，也不安装 placeholder 或分配 descriptor；函数前的大段旧注释描述的是延迟属性机制，不是本函数行为。

### `Object.createPropAutoInitSlot` (`src/core/object.zig:8517`)

- **签名**：`fn createPropAutoInitSlot( self: *Object, rt: *JSRuntime, explicit_global: ?*Object, info: property.AutoInit, ) !property.AutoInitSlot`。
- **作用**：构造动态 PROP 描述信息的延迟槽，并按配置保护对象输入。
- **实现**：value_root_frames_enabled 时 rootObjects(self,explicit_global) 覆盖 createPropAutoInitSlotWork，退出撤销；否则直接调用 Work。
- **所有权 / 错误 / 调用**：显式根帧受编译期开关控制，不是无条件保护；分配/realm 查询失败传播，不安装属性。

### `Object.createPropAutoInitSlotWork` (`src/core/object.zig:8536`)

- **签名**：`inline fn createPropAutoInitSlotWork( self: *Object, rt: *JSRuntime, explicit_global: ?*Object, info: property.AutoInit, ) !property.AutoInitSlot`。
- **作用**：解析 realm、驻留 AutoInit 信息并构造 PROP 槽。
- **实现**：autoInitRealmForDefinition 后 property.internAutoInit(rt,info)，最后 AutoInitSlot.retainProp(realm.header,stored)。
- **所有权 / 错误 / 调用**：可能在 intern 时分配失败；槽持有 realm 追踪边和 descriptor 指针，不表示执行 RC retain 或立即构建函数。

### `Object.defineAutoInitPropertyFromDescriptor` (`src/core/object.zig:8550`)

- **签名**：`pub fn defineAutoInitPropertyFromDescriptor( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm_global: ?*Object, info: *const property.AutoInit, ) !void`。
- **作用**：用已有不可变 descriptor 指针定义延迟属性。
- **实现**：先 autoInitRealmForDefinition 解析 realm，再委托 WithResolvedRealm。
- **所有权 / 错误 / 调用**：不复制/驻留 descriptor，调用者必须保证其寿命覆盖属性；解析与追加错误传播。

### `Object.defineAutoInitPropertyFromDescriptorWithResolvedRealm` (`src/core/object.zig:8565`)

- **签名**：`pub fn defineAutoInitPropertyFromDescriptorWithResolvedRealm( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, resolved_realm: *context_mod.RealmContext, info: *const property.AutoInit, ) !void`。
- **作用**：用已解析 realm 和稳定 descriptor 追加 auto-init 属性。
- **实现**：断言无 exotic、plain storage、非 mapped_arguments、extensible、realm.runtime==rt；以 flags.withKind(auto_init) 和 retainProp 槽调用 appendPreparedPropertyEntry。
- **所有权 / 错误 / 调用**：不查重、不重复解析 realm、不构建目标值；descriptor 借用须长期有效，保留输入 flags 的其他位。追加可能分配失败。

### `Object.defineModuleVarRefProperty` (`src/core/object.zig:8586`)

- **签名**：`pub fn defineModuleVarRefProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, owned_cell: *var_ref_mod.VarRef, ) !void`。
- **作用**：向 namespace 添加直接引用 exporter VarRef 的属性。
- **实现**：class 非 module_ns、不可扩展或同名属性已存在则 IncompatibleDescriptor；否则 appendPreparedPropertyEntry，flags 为 var_ref、writable/enumerable true、configurable false。
- **所有权 / 错误 / 调用**：成功槽共享 supplied cell，不复制 binding 值；当前没有失败时 RC 消耗/释放的代码。caller 负责 cell 的存活和模块链接合同。

### `Object.defineModuleAutoInitProperty` (`src/core/object.zig:8605`)

- **签名**：`pub fn defineModuleAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, realm: *context_mod.RealmContext, owner: *const property.AutoInitModuleOwner, ) !void`。
- **作用**：向 namespace 添加延迟解析的 export 属性。
- **实现**：验证 module_ns、extensible 和无重复 key，失败 IncompatibleDescriptor；成功委托 appendModuleAutoInitProperty，输入 flags 为可写可枚举不可配置。
- **所有权 / 错误 / 调用**：不立即执行 module owner.resolve；owner 接口指针必须稳定，存活依赖相应 realm/module 图。

### `Object.defineModuleAutoInitPropertyForFixture` (`src/core/object.zig:8646`)

- **签名**：`pub fn defineModuleAutoInitPropertyForFixture( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm: *context_mod.RealmContext, owner: *const property.AutoInitModuleOwner, ) !void`。
- **作用**：W1b3d1 的 fixture 接缝：让调用方自带 flags 安装 module namespace 延迟 export，复用与真实 namespace 属性相同的槽构造器。
- **实现**：本函数只有一步，直接 try self.appendModuleAutoInitProperty(rt, atom_id, flags, realm, owner)；断言（realm.runtime==rt、supportsPlainNamedPropertyStorage、extensible）与 flags.withKind(.auto_init)、AutoInitSlot.retainModule 的构造都在该 helper 内完成。
- **所有权 / 错误 / 调用**：与 defineModuleAutoInitProperty 不同，这里不检查 class 是否 module_ns、不查重、也不强制「可写可枚举不可配置」的 flags；槽只持有 realm 追踪边和 owner 接口指针，owner 的寿命由调用方保证，追加时的分配错误传播。


### `Object.defineAutoInitProperty` (`src/core/object.zig:8657`)

- **签名**：`pub fn defineAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, length: i32, flags: property.Flags, ) !void`。
- **作用**：定义由 receiver 推导 realm 的延迟函数属性。
- **实现**：委托 defineAutoInitPropertyWithRealm，realm_global=null。
- **所有权 / 错误 / 调用**：只安装 placeholder，不立即创建函数；继承下层新属性、布局与错误协议。

### `Object.defineAutoInitPropertyWithRealm` (`src/core/object.zig:8668`)

- **签名**：`pub fn defineAutoInitPropertyWithRealm( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, length: i32, flags: property.Flags, realm_global: ?*Object, ) !void`。
- **作用**：定义可指定 realm global 的延迟函数属性。
- **实现**：委托 WithRealmAndNative，native_builtin_id=0。
- **所有权 / 错误 / 调用**：null global 由 receiver 解析，非空则使用明确 global；无 native id 不意味着已经解析实际调用目标。

### `Object.defineAutoInitPropertyWithRealmAndNative` (`src/core/object.zig:8680`)

- **签名**：`pub fn defineAutoInitPropertyWithRealmAndNative( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, length: i32, flags: property.Flags, realm_global: ?*Object, native_builtin_id: i32, ) !void`。
- **作用**：追加包含函数 name/length/native id 的 PROP placeholder。
- **实现**：断言无 exotic、plain storage、非 mapped_arguments、extensible；createPropAutoInitSlot 构造信息，再 appendPreparedPropertyEntry，flags 改为 auto_init。
- **所有权 / 错误 / 调用**：不查重或物化；descriptor 驻留与属性追加均可能失败，追加失败不回滚已驻留的 runtime 信息。无需沿用旧注释的 RC dup 解释。

### `Object.replaceAutoInitPropertyWithRealmAndNative` (`src/core/object.zig:8706`)

- **签名**：`pub fn replaceAutoInitPropertyWithRealmAndNative( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, length: i32, flags: property.Flags, realm_global: ?*Object, native_builtin_id: i32, ) !void`。
- **作用**：替换现有 auto-init 描述信息，缺失时追加。
- **实现**：命中非 auto-init 报 TypeError；命中 auto-init 时若新旧 flags bits 不同先 ensureUniqueShapeForMutation，再创建 next_slot，setEntryKindAndSlot 后 prune holder。无同名属性则调用 define 入口。
- **所有权 / 错误 / 调用**：构造 next_slot 失败前不发布新槽/flags，但 Shape 克隆或 descriptor 驻留可能已经发生。不会物化被替换 placeholder。

### `Object.replaceAutoInitPropertyWithData` (`src/core/object.zig:8741`)

- **签名**：`pub fn replaceAutoInitPropertyWithData( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, source_value: JSValue, flags: property.Flags, ) !void`。
- **作用**：把已有 auto-init 属性替换为共享的 data 值。
- **实现**：属性缺失或旧 flags 非 auto-init 报 IncompatibleDescriptor；ensureUniqueShapeForMutation 后写 data、屏障值、按输入 flags.withKind(data) 更新描述符，再 prune holder。
- **所有权 / 错误 / 调用**：不调用旧 builder，不复制函数对象或保持源/别名属性槽联动；只是共享 source_value 的身份。未检查原 configurable，专供受控 bootstrap。

### `Object.defineNavigatorAutoInitProperty` (`src/core/object.zig:8764`)

- **签名**：`pub fn defineNavigatorAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm_global: *Object, ) !void`。
- **作用**：追加 navigator 专用延迟属性。
- **实现**：断言无 exotic、plain named storage、extensible；显式 realm_global，创建 name=navigator、length=0、kind=navigator 信息，再 appendPreparedPropertyEntry，改 flags.kind 为 auto_init。
- **所有权 / 错误 / 调用**：不查重、不立即创建 navigator 对象；输入 flags 的其他位保留，slot 创建/追加错误传播。

### `Object.defineConsoleAutoInitProperty` (`src/core/object.zig:8781`)

- **签名**：`pub fn defineConsoleAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, host_function_kind: i32, entry: ?*const native_entry.NativeEntry, ) !void`。
- **作用**：追加 console 专用延迟描述信息。
- **实现**：断言 host kind 非零、无 exotic、plain storage、extensible；用 null explicit global 构造 name=console,length=0,kind=console,host kind/native entry 信息，然后追加 auto-init 槽。
- **所有权 / 错误 / 调用**：realm 从 receiver 解析；不创建 log/warn/error 函数，不查重。原 flags 的其他位保留。

### `Object.definePerformanceAutoInitProperty` (`src/core/object.zig:8802`)

- **签名**：`pub fn definePerformanceAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm_global: *Object, ) !void`。
- **作用**：追加 performance 专用延迟属性。
- **实现**：断言无 exotic、plain named storage、extensible；显式 realm_global，创建 name=performance、length=0、kind=performance 信息，再 appendPreparedPropertyEntry，改 flags.kind 为 auto_init。
- **所有权 / 错误 / 调用**：不查重、不立即创建 performance 对象；输入 flags 的其他位保留，slot 创建/追加错误传播。

### `Object.defineBuiltinNamespaceAutoInitProperty` (`src/core/object.zig:8819`)

- **签名**：`pub fn defineBuiltinNamespaceAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, flags: property.Flags, realm_global: *Object, kind: property.AutoInitKind, ) !void`。
- **作用**：追加 Math/JSON/Reflect/Atomics namespace 延迟槽。
- **实现**：断言 kind 属于四类 namespace，且无 exotic、plain storage、extensible；显式 realm_global，信息为 name、length=0、指定 kind，追加 flags.withKind(auto_init)。
- **所有权 / 错误 / 调用**：不立即调用 namespace callback、不查重或创建成员；创建 descriptor/追加可失败。

### `Object.defineEmptyArrayAutoInitProperty` (`src/core/object.zig:8842`)

- **签名**：`pub fn defineEmptyArrayAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm_global: *Object, ) !void`。
- **作用**：在可配置属性上安装延迟空数组，按配置保护 holder/global。
- **实现**：value_root_frames_enabled 时用 rootObjects(self,realm_global) 包住 Mut 调用，否则直接委托。
- **所有权 / 错误 / 调用**：显式 root frame 并非无条件启用，不提前创建数组；错误传播。

### `Object.defineEmptyArrayAutoInitPropertyMut` (`src/core/object.zig:8862`)

- **签名**：`inline fn defineEmptyArrayAutoInitPropertyMut( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm_global: *Object, ) !void`。
- **作用**：追加或替换为 empty-array placeholder。
- **实现**：断言无 exotic、plain storage、非 mapped_arguments、extensible、输入非 accessor。命中属性要求 configurable，准备唯一 Shape 后创建 name="empty array",length=0,kind=empty_array 的槽，setEntryKindAndSlot 并 prune；未命中直接创建并追加。
- **所有权 / 错误 / 调用**：可替换旧 data/accessor 等 configurable 属性，不只旧 auto-init；不执行旧 getter/builder。失败前可能已有 Shape/descriptor 分配变化，但新槽在准备完成后才安装。

### `Object.defineHostAutoInitProperty` (`src/core/object.zig:8898`)

- **签名**：`pub fn defineHostAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, length: i32, flags: property.Flags, host_function_kind: i32, host_function_prototype: bool, realm_global: ?*Object, ) !void`。
- **作用**：安装不带显式 NativeEntry 的 host 延迟属性。
- **实现**：原样传递参数给 WithEntry，entry=null。
- **所有权 / 错误 / 调用**：不立即构造函数；继承下层新属性、realm 与分配错误合同。

### `Object.defineHostAutoInitPropertyWithEntry` (`src/core/object.zig:8922`)

- **签名**：`pub fn defineHostAutoInitPropertyWithEntry( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, name: []const u8, length: i32, flags: property.Flags, host_function_kind: i32, host_function_prototype: bool, realm_global: ?*Object, entry: ?*const native_entry.NativeEntry, ) !void`。
- **作用**：追加 host-function 描述信息的 auto-init 槽。
- **实现**：断言 host kind 非零、无 exotic、plain storage、非 mapped_arguments、extensible；createPropAutoInitSlot 保存 name/length/host kind/entry/prototype 标志，再追加 flags.withKind(auto_init)。
- **所有权 / 错误 / 调用**：不查重或调用 entry；realm 按 explicit global/receiver 解析，entry 指针寿命由调用方保证。

### `Object.materializeMappedArgumentsProperty` (`src/core/object.zig:10995`)

- **签名**：`fn materializeMappedArgumentsProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom) !void`。
- **作用**：为仍映射的索引按需创建普通 data 属性。
- **实现**：从 atom 找 live mapping；已有 shape 项直接返回，否则读取 mapped 值并 addProperty(w/e/c 全 true)。
- **所有权 / 错误 / 调用**：保留原映射，不 detach；创建的 data 是当前值副本，mapped 读路径继续优先读 cell。分配失败传播。

### `Object.materializeAllMappedArgumentsProperties` (`src/core/object.zig:11002`)

- **签名**：`fn materializeAllMappedArgumentsProperties(self: *Object, rt: *JSRuntime) !void`。
- **作用**：为所有非空 mapped 项确保普通属性存在。
- **实现**：非 mapped class 返回；遍历 refs，对非空项用 atomFromUInt32(index) 调用单项物化。
- **所有权 / 错误 / 调用**：中途失败保留已经创建的属性，不解除任何映射。

## 覆盖核对

- 清单函数数（本文件分到）: 47（`src/core/object.zig` 全文件 879）
- 本文标题覆盖: 47
- 未覆盖: 无
