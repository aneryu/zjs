# 07 — class payload 槽（`src/core/object.zig`）

iterator / Map-Set / FinalizationRegistry / ArrayBuffer / TypedArray / RegExp / bound / Proxy / arguments / WeakRef / dense array / Promise / generator 的槽访问器，以及文件后部的私有 `*Payload()` / `destroy*Payload`。函数对象见 [07-object-function.md](07-object-function.md)。

命名只能帮助定位，不能替代各函数的合同：多数 Slot 接口返回可变字段指针，但也有返回值的例外；部分接口遇到缺失 payload 会 unreachable，其他接口返回默认值。unreachable 是调用前提，不能依赖发布构建仍有安全检查。ensure 接口按具体 payload 的分配和析构模型创建存储，屏障、finalizer 标记与错误清理也须逐项查看。

`payloadArm` 断言非 slots2；普通对象在 `ensureOrdinaryPayload` 时若仍是 slots2 会先 spill 属性。

---


### `Object.value` (`src/core/object.zig:2205`)

- **签名**：`pub fn value(self: *Object) JSValue`。
- **作用**：将Object借用表示为JSValue。
- **实现**：JSValue.object(self.gcHeader())。
- **所有权 / 错误 / 调用**：无分配、pin或深复制，不延长对象生命周期。

### `Object.cachedIteratorNextSlot` (`src/core/object.zig:2209`)

- **签名**：`pub fn cachedIteratorNextSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：取得或创建runtime侧表中的iterator next缓存槽。
- **实现**：已存在则返回；满容量时从0扩至4或翻倍，allocRuntime新表、memcpy旧有效项、替换表和容量后释放旧buffer。追加object=self的默认entry，markNeedsFinalizer并返回value字段地址。
- **所有权 / 错误 / 调用**：返回借用指针会被后续扩容或swap-remove失效，不可跨任意表变更保存。首次分配失败不追加；已有槽直接返回，不再置finalizer。这里只建槽，不安装具体JSValue或执行其写屏障。

### `Object.cachedIteratorNext` (`src/core/object.zig:2234`)

- **签名**：`pub fn cachedIteratorNext(self: *const Object, rt: *JSRuntime) ?JSValue`。
- **作用**：查询已缓存的next值。
- **实现**：空表或无对应entry返回null，否则读slot.*。
- **所有权 / 错误 / 调用**：未建entry和entry.value为空均表现为null；不查对象属性、不调用getter，也不创建缓存。

### `Object.clearCachedIteratorNext` (`src/core/object.zig:2240`)

- **签名**：`pub fn clearCachedIteratorNext(self: *Object, rt: *JSRuntime) void`。
- **作用**：清空并移除对象的next缓存entry。
- **实现**：空表/未找到返回；value置null，再removeCachedIteratorNextEntryAt。
- **所有权 / 错误 / 调用**：不调用JSValue释放、不缩减capacity，也不清对象needs_finalizer；旧值后续由GC判断可达性。

### `Object.cachedIteratorNextSlotIfPresent` (`src/core/object.zig:2247`)

- **签名**：`fn cachedIteratorNextSlotIfPresent(self: *const Object, rt: *JSRuntime) ?*?JSValue`。
- **作用**：借用已存在缓存entry的可变value槽。
- **实现**：空表返回null，按object地址查index，返回value字段指针。
- **所有权 / 错误 / 调用**：const Object不意味着返回槽只读；无分配，指针受侧表扩容及移除影响。

### `Object.cachedIteratorNextSlotForCycleGc` (`src/core/object.zig:2254`)

- **签名**：`pub fn cachedIteratorNextSlotForCycleGc(self: *const Object, rt: *JSRuntime) ?*?JSValue`。
- **作用**：向collector提供已存在的缓存强边槽。
- **实现**：委托cachedIteratorNextSlotIfPresent。
- **所有权 / 错误 / 调用**：不自行追踪/标记，不创建entry或延长槽地址有效期。

### `Object.cachedIteratorNextEntryIndex` (`src/core/object.zig:2258`)

- **签名**：`fn cachedIteratorNextEntryIndex(rt: *const JSRuntime, self: *const Object) ?usize`。
- **作用**：在线性侧表中按对象身份查缓存索引。
- **实现**：空表早退；遍历entries比较entry.object==self，返回第一个index，否则null。
- **所有权 / 错误 / 调用**：O(n)指针相等查询，不比较JS值或属性；依赖销毁时清除裸Object地址。

### `Object.removeCachedIteratorNextEntryAt` (`src/core/object.zig:2266`)

- **签名**：`fn removeCachedIteratorNextEntryAt(rt: *JSRuntime, index: usize) void`。
- **作用**：无序删除一个缓存entry。
- **实现**：计算len-1；若非末项则用末项覆盖index，再缩短slice到last_index。
- **所有权 / 错误 / 调用**：不保留顺序、不清旧末尾或释放capacity；要求非空表和合法index，不执行value资源清理。

### `Object.createPromiseReactionRecord` (`src/core/object.zig:2274`)

- **签名**：`pub fn createPromiseReactionRecord(rt: *JSRuntime) !*Object`。
- **作用**：创建普通Object并挂专用promise reaction payload cell。
- **实现**：先create普通null-prototype对象，设置错误时destroyFromHeader；激活rootObjects作用域，createPayloadCell，安装payload槽与kind，再rememberOwnerForBulkWrite并返回。
- **所有权 / 错误 / 调用**：这是普通Object class配专用私有payload，不是Promise实例。root作用域的实际链接受构建模式控制；失败由对象析构清理，已mint的GC cell不手动free。

### `Object.ensureOrdinaryPayload` (`src/core/object.zig:2287`)

- **签名**：`pub fn ensureOrdinaryPayload(self: *Object, rt: *JSRuntime) !*OrdinaryPayload`。
- **作用**：取得或按需安装ordinary payload。
- **实现**：已有ordinary直接返回；若为reaction record则新建OrdinaryPayload，复制三个reaction字段，替换槽/kind并bulk barrier。其它情况断言kind none；slots2先spill属性并饱和增加attach计数，再createPayloadCell、安装槽/kind及barrier。
- **所有权 / 错误 / 调用**：reaction转换不深复制引用；旧cell交GC。slots2路径若spill成功而后payload分配失败，属性存储和计数已变化，不能宣称全部OOM都保持对象完全不变。

### `Object.spillInlinePropertyStorageForPayload` (`src/core/object.zig:2329`)

- **签名**：`fn spillInlinePropertyStorageForPayload(self: *Object, rt: *JSRuntime) !void`。
- **作用**：为slots2对象挂payload腾出尾部首字。
- **实现**：断言slots2及plain Object；已非inline返回。capacity0时要求prop_count0并设置空存储哨兵；否则要求capacity<=2，创建property storage cell，复制prop_count项、安装external指针并bulk barrier。
- **所有权 / 错误 / 调用**：不清slots2布局标志、不缩减原分配或安装payload。成功后旧尾部字节仍存在但不再作为当前property存储，失败在安装前保持原存储。

### `Object.globalLexicals` (`src/core/object.zig:2351`)

- **签名**：`pub fn globalLexicals(self: *const Object, rt: *const JSRuntime) ?*Object`。
- **作用**：取得global对象所属context的lexicals对象。
- **实现**：contextForGlobalIncludingConstructing无结果返回null，否则ctx.lexicals。
- **所有权 / 错误 / 调用**：包含构造中的context查询；借用结果，不创建或pin，也不从普通属性查找。

### `Object.setGlobalLexicals` (`src/core/object.zig:2356`)

- **签名**：`pub fn setGlobalLexicals(self: *Object, rt: *JSRuntime, v: ?*Object) !void`。
- **作用**：更新global对应context的lexicals字段。
- **实现**：无context返回InvalidBuiltinRegistry，否则ctx.lexicals=v。
- **所有权 / 错误 / 调用**：本函数没有分配或显式GC barrier，也不销毁旧值；根可达性由context协议负责，不能把该赋值描述成Object属性存储写入。

### `Object.globalUninitializedVars` (`src/core/object.zig:2362`)

- **签名**：`pub fn globalUninitializedVars(self: *const Object) ?*Object`。
- **作用**：查询global payload的未初始化变量表对象。
- **实现**：globalPayloadConst存在返回uninitialized_vars，否则null。
- **所有权 / 错误 / 调用**：不懒创建payload、不查context.lexicals，两者不是同一字段。

### `Object.setGlobalUninitializedVars` (`src/core/object.zig:2366`)

- **签名**：`pub fn setGlobalUninitializedVars(self: *Object, rt: *JSRuntime, v: ?*Object) !void`。
- **作用**：更新global payload中的未初始化变量表强边。
- **实现**：ensureGlobalPayload后赋uninitialized_vars；v非null时调用owner到env的generationalBarrier。
- **所有权 / 错误 / 调用**：懒分配可能OOM，成功设置null不执行目标屏障；不写context.lexicals或普通属性。

### `Object.promoteToGlobalObjectClass` (`src/core/object.zig:2381`)

- **签名**：`pub fn promoteToGlobalObjectClass(self: *Object, rt: *JSRuntime) void`。
- **作用**：将对象class改为global并标记析构责任。
- **实现**：直接赋class_id=global_object，再markNeedsFinalizer。
- **所有权 / 错误 / 调用**：没有重新分配或布局转换，也不检查原class；调用方必须保证兼容布局。此函数是class通常固定的明确例外，不能把不可变class当作无例外事实。

### `Object.ensureGlobalPayload` (`src/core/object.zig:2386`)

- **签名**：`pub fn ensureGlobalPayload(self: *Object, rt: *JSRuntime) !*GlobalPayload`。
- **作用**：取得或懒挂载GlobalPayload cell。
- **实现**：已有globalPayload则返回；否则断言global class，createPayloadCell，写payloadArm、kind=global，再bulk barrier。
- **所有权 / 错误 / 调用**：不保留被替换的其它payload内容，要求调用方提供可挂载状态；不创建RealmContext。

### `Object.ensureRealmPayload` (`src/core/object.zig:2399`)

- **签名**：`pub fn ensureRealmPayload(self: *Object, rt: *JSRuntime) !*GlobalPayload`。
- **作用**：兼容旧命名的global payload获取入口。
- **实现**：class为普通Object时先promoteToGlobalObjectClass，再ensureGlobalPayload。
- **所有权 / 错误 / 调用**：不安装Realm引用；若后续分配失败，class转换及finalizer位已生效，不能承诺全回滚。

### `Object.installOwnedRealmRef` (`src/core/object.zig:2404`)

- **签名**：`pub fn installOwnedRealmRef(self: *Object, rt: *JSRuntime, owner: *context_mod.RealmRef) !void`。
- **作用**：把已有RealmRef所有权转入新RealmRecordPayload。
- **实现**：断言payloadArm为空及owner非空；createRuntime成功后将owner值存入payload.realm，清owner，再安装槽/kind并标finalizer。
- **所有权 / 错误 / 调用**：分配失败不消费owner；成功后由payload持有RealmRef边；当前RealmRef.deinit只清空指针，不执行RC释放。非GC payload普通分配，没有这里额外的generationalBarrier，不可描述为GC cell发布。

### `Object.realmContext` (`src/core/object.zig:2415`)

- **签名**：`pub fn realmContext(self: *const Object) ?*context_mod.RealmContext`。
- **作用**：从realm_record payload借用RealmContext。
- **实现**：kind不匹配或槽null返回null，否则转RealmRecordPayload并realm.borrow。
- **所有权 / 错误 / 调用**：不retain或创建Realm；仅适用合法非slots2 payload布局。

### `Object.bytecodeFunctionAux` (`src/core/object.zig:2424`)

- **签名**：`inline fn bytecodeFunctionAux(self: *Object) ?*BytecodeFunctionAux`。
- **作用**：解码bytecode函数的带低位tag辅助记录。
- **实现**：非bytecode class或home_or_aux为空返回null；最低位bit0未置返回null，否则清bit0转aux指针。
- **所有权 / 错误 / 调用**：未置tag的非空字是直接home Object，不是aux；返回可变借用，不验证地址生命周期。

### `Object.bytecodeFunctionAuxConst` (`src/core/object.zig:2432`)

- **签名**：`inline fn bytecodeFunctionAuxConst(self: *const Object) ?*const BytecodeFunctionAux`。
- **作用**：只读解码bytecode函数辅助记录。
- **实现**：同样检查class、非空、最低位tag，清tag返回const aux。
- **所有权 / 错误 / 调用**：不改变home_or_aux或创建辅助cell。

### `Object.encodeBytecodeFunctionAux` (`src/core/object.zig:2440`)

- **签名**：`inline fn encodeBytecodeFunctionAux(aux: *BytecodeFunctionAux) *anyopaque`。
- **作用**：把aux指针编码为home_or_aux的tagged表示。
- **实现**：将整数地址与bytecode_function_aux_tag=1按位或再转opaque指针。
- **所有权 / 错误 / 调用**：依赖真实aux地址最低位原为0，不做运行时对齐断言；编码指针须先清tag才可解引用。

### `Object.ensureFunctionRarePayload` (`src/core/object.zig:2444`)

- **签名**：`fn ensureFunctionRarePayload(self: *Object, rt: *JSRuntime) !*FunctionRarePayload`。
- **作用**：按bytecode或native函数路线取得/创建rare状态。
- **实现**：bytecode已有aux返回rare字段；否则createPayloadCell(BytecodeFunctionAux)，将旧未tag的home指针复制为aux.home_object，写tagged aux并bulk barrier。非bytecode取得functionPayload，无则直接 error.TypeError；已有rare返回，否则createRuntime默认FunctionRarePayload并安装。
- **所有权 / 错误 / 调用**：两条路线分配与生命周期不同，native rare不是此处mint的GC cell。bytecode迁移保留home引用，成功后才替换原槽；不初始化具体rare业务状态。TypeError 分支原先还挂着 `assert(kind == .function)`——进入该分支恰恰意味着 kind 不是 .function，safety 构建里必然先 abort，断言已删除，错误映射现在在所有构建模式下一致。

### `Object.functionRarePayload` (`src/core/object.zig:2471`)

- **签名**：`fn functionRarePayload(self: *Object) ?*FunctionRarePayload`。
- **作用**：查询已有可变函数rare状态。
- **实现**：aux存在返回其rare字段，否则functionPayload存在则返回payload.rare，缺失返回null。
- **所有权 / 错误 / 调用**：不分配，不强制创建aux；借用内部字段。

### `Object.functionRarePayloadConst` (`src/core/object.zig:2477`)

- **签名**：`fn functionRarePayloadConst(self: *const Object) ?*const FunctionRarePayload`。
- **作用**：查询已有只读函数rare状态。
- **实现**：先aux const，后native payload const的rare，缺失null。
- **所有权 / 错误 / 调用**：不retain，不保证rare存在。

### `Object.installExternalClassPayload` (`src/core/object.zig:2483`)

- **签名**：`pub fn installExternalClassPayload(self: *Object, rt: *JSRuntime, payload: *anyopaque) void`。
- **作用**：安装宿主opaque payload并登记析构责任。
- **实现**：断言payloadArm为空，写payload指针、kind=none，再markNeedsFinalizer。
- **所有权 / 错误 / 调用**：none不等于无payload；释放责任由class回调合同承担，此函数不复制资源或设置native标志。

### `Object.assertOnlyPayloadWordIsLive` (`src/core/object.zig:2502`)

- **签名**：`inline fn assertOnlyPayloadWordIsLive(self: *const Object) void`。
- **作用**：在安全构建检查宽臂的附加状态是否为空。
- **实现**：非安全构建返回；窄8字节臂直接返回；宽臂断言array view的count/capacity/length为0。
- **所有权 / 错误 / 调用**：不检查首字指针有效性或padding，不证明任何class都能按payload解释；仅局部布局约束。

### `Object.nativeSelf` (`src/core/object.zig:2512`)

- **签名**：`pub inline fn nativeSelf(self: *const Object) ?*anyopaque`。
- **作用**：查询NativeObject的opaque self。
- **实现**：is_native_object为false返回null，否则返回payloadArm内容。
- **所有权 / 错误 / 调用**：disposed槽为空也返回null；不校验期望NativeType class，不pin宿主资源。

### `Object.nativeSelfAssumeClass` (`src/core/object.zig:2520`)

- **签名**：`pub inline fn nativeSelfAssumeClass(self: *const Object) ?*anyopaque`。
- **作用**：在调用方已匹配class的前提下读取native self。
- **实现**：断言is_native_object后读payloadArm。
- **所有权 / 错误 / 调用**：函数本身没有class_id比较；可能null，调用方负责disposed时的错误处理。

### `Object.installNativeSelf` (`src/core/object.zig:2528`)

- **签名**：`pub fn installNativeSelf(self: *Object, rt: *JSRuntime, self_ptr: *anyopaque) void`。
- **作用**：在NativeObject中安装宿主实例指针。
- **实现**：先installExternalClassPayload，再is_native_object=true。
- **所有权 / 错误 / 调用**：要求空payload槽及对应注册class合同，函数不注册NativeType或检查其id。

### `Object.takeNativeSelf` (`src/core/object.zig:2536`)

- **签名**：`pub fn takeNativeSelf(self: *Object) ?*anyopaque`。
- **作用**：断开NativeObject的宿主指针并交给调用方。
- **实现**：非native返回null；否则取payload槽旧值、置null并返回。
- **所有权 / 错误 / 调用**：不执行宿主finalize/dispose，不清native/finalizer标志。后续调用是否抛TypeError由receiver检查实现，不是本函数直接抛出。

### `Object.externalClassPayload` (`src/core/object.zig:2544`)

- **签名**：`pub fn externalClassPayload(self: *Object) ?*anyopaque`。
- **作用**：借用当前确属external payload路线的首字指针。
- **实现**：slots2、Array、fast_array、mapped_arguments、async resume类或payload_kind非none均返回null；其余assertOnlyPayloadWordIsLive，并断言指针要么为空、要么不等于空属性存储哨兵（@alignOf(JSValue)），返回payloadArm。
- **所有权 / 错误 / 调用**：none可承载宿主或trailing-inline payload，不代表必为空；返回不证明宿主类型或所有权，排除名单须与新增inline臂保持一致。

### `Object.externalClassPayloadConst` (`src/core/object.zig:2555`)

- **签名**：`pub fn externalClassPayloadConst(self: *const Object) ?*anyopaque`。
- **作用**：从只读Object查询external payload指针。
- **实现**：与可变版本使用同一排除条件及局部布局断言，然后返回payloadArm内容。
- **所有权 / 错误 / 调用**：返回类型仍是?*anyopaque，而非const payload；只读Object参数不保证宿主内存只读。

### `Object.setCachedFunctionProto` (`src/core/object.zig:2563`)

- **签名**：`pub fn setCachedFunctionProto(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void`。
- **作用**：更新所属Realm的Function prototype缓存并屏障。
- **实现**：找不到含构造中global对应context则InvalidBuiltinRegistry；写ctx.cached_function_proto。值非null且context已heap_accounted时，以context header为owner执行generationalBarrier。
- **所有权 / 错误 / 调用**：owner是Realm不是global Object；构造中未发布Realm跳过此屏障，空值也跳过。不执行原型链变更或销毁旧值。

### `Object.cachedFunctionProto` (`src/core/object.zig:2574`)

- **签名**：`pub fn cachedFunctionProto(self: *const Object, rt: *const JSRuntime) ?*Object`。
- **作用**：查询Realm缓存的Function prototype。
- **实现**：找不到对应context返回null，否则ctx.cached_function_proto。
- **所有权 / 错误 / 调用**：借用指针，不初始化intrinsic，也不查普通prototype属性。

### `Object.setCachedPromiseProto` (`src/core/object.zig:2579`)

- **签名**：`pub fn setCachedPromiseProto(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void`。
- **作用**：更新Realm的Promise prototype缓存。
- **实现**：无对应context返回InvalidBuiltinRegistry；赋cached_promise_proto，对非空值且已发布context执行Realm-owner屏障。
- **所有权 / 错误 / 调用**：不创建Promise或安装属性；构造中Realm与null值不进入屏障分支。

### `Object.cachedPromiseProto` (`src/core/object.zig:2590`)

- **签名**：`pub fn cachedPromiseProto(self: *const Object, rt: *const JSRuntime) ?*Object`。
- **作用**：读取对应Realm的Promise prototype缓存。
- **实现**：查context，无则null，否则返回cached_promise_proto。
- **所有权 / 错误 / 调用**：不懒构造缓存对象、不pin。

### `Object.setCachedRealmValue` (`src/core/object.zig:2600`)

- **签名**：`pub fn setCachedRealmValue(self: *Object, rt: *JSRuntime, slot: RealmValueSlot, next_value: ?JSValue) !void`。
- **作用**：写入指定Realm缓存槽并处理其GC边。
- **实现**：先查context，无则错误；cached_values[enum(slot)]赋next_value。非null且Realm已accounted时对cycleMarkHeader调用Realm-owner屏障。
- **所有权 / 错误 / 调用**：没有RC dup/free；primitive没有可追踪header时屏障入口会早退。slot枚举决定位置，不执行JS属性setter。

### `Object.setRealmRegExpLegacySlot` (`src/core/object.zig:2619`)

- **签名**：`pub fn setRealmRegExpLegacySlot(self: *Object, rt: *JSRuntime, slot: *?JSValue, next_value: ?JSValue) void`。
- **作用**：更新调用方提供的RegExp legacy槽，并以所属Realm执行屏障。
- **实现**：先slot.*=next_value，再查context，无则直接返回；存在且值非null、Realm已accounted时屏障。
- **所有权 / 错误 / 调用**：与setCachedRealmValue不同，无context仍已完成写入且不报错；不验证slot真的属于该Realm，调用方必须保证归属和指针有效。

### `Object.cachedRealmValue` (`src/core/object.zig:2627`)

- **签名**：`pub fn cachedRealmValue(self: *const Object, rt: *const JSRuntime, slot: RealmValueSlot) ?JSValue`。
- **作用**：查询指定Realm缓存槽的可选JSValue。
- **实现**：无context返回null，否则按slot枚举读取cached_values。
- **所有权 / 错误 / 调用**：只读值表示，不retain或求值；null既可能无context也可能槽未设置。

### `Object.cachedThrowTypeErrorIntrinsic` (`src/core/object.zig:2632`)

- **签名**：`pub fn cachedThrowTypeErrorIntrinsic(self: *const Object, rt: *const JSRuntime) ?JSValue`。
- **作用**：取得Realm的throw_type_error_intrinsic缓存值。
- **实现**：委托cachedRealmValue(rt,.throw_type_error_intrinsic)。
- **所有权 / 错误 / 调用**：不调用该函数、不触发TypeError，缓存缺失返回null。

### `Object.iteratorTargetSlot` (`src/core/object.zig:3104`)

- **签名**：`pub fn iteratorTargetSlot(self: *Object) *?JSValue`。
- **作用**：取得iterator target的可变槽。
- **实现**：iteratorPayload存在返回字段地址；否则断言kind iterator再unreachable。
- **所有权 / 错误 / 调用**：不是可空查询，不创建payload或执行写屏障，调用者必须满足iterator payload合同。

### `Object.iteratorLengthSlot` (`src/core/object.zig:3110`)

- **签名**：`pub fn iteratorLengthSlot(self: *Object) *u32`。
- **作用**：取得iterator length的可变字段。
- **实现**：payload存在返回&length，否则断言并unreachable。
- **所有权 / 错误 / 调用**：裸写不验证索引或状态；借用期限受payload生命周期约束。

### `Object.iteratorLength` (`src/core/object.zig:3116`)

- **签名**：`pub fn iteratorLength(self: *const Object) u32`。
- **作用**：查询iterator记录长度。
- **实现**：有iteratorPayloadConst返回length，否则0。
- **所有权 / 错误 / 调用**：缺失payload与实际零长度不可区分，不抛类型错误。

### `Object.setIteratorLength` (`src/core/object.zig:3121`)

- **签名**：`pub fn setIteratorLength(self: *Object, length: u32) void`。
- **作用**：直接更新iterator记录长度。
- **实现**：iteratorLengthSlot().*=length。
- **所有权 / 错误 / 调用**：不调整target、当前位置或元素存储，继承槽访问的前提。

### `Object.arrayLength` (`src/core/object.zig:3125`)

- **签名**：`pub fn arrayLength(self: *const Object) u32`。
- **作用**：读取Array的可见length字段。
- **实现**：isArray时返回arrayArm.length，非Array返回0。
- **所有权 / 错误 / 调用**：不读取普通对象length属性或Arguments own length，也不调用getter。

### `Object.setArrayLength` (`src/core/object.zig:3134`)

- **签名**：`pub fn setArrayLength(self: *Object, length: u32) void`。
- **作用**：仅更新Array内部可见length。
- **实现**：断言isArray后直接写arrayArm.length。
- **所有权 / 错误 / 调用**：不检查length_writable、不删除元素或截断count，不改变fast_array；调用方先执行JS语义校验并配合必要的truncate。

### `Object.hasExoticMethods` (`src/core/object.zig:3139`)

- **签名**：`pub fn hasExoticMethods(self: *const Object) bool`。
- **作用**：读取对象缓存的exotic方法标志。
- **实现**：返回flags.has_exotic_methods。
- **所有权 / 错误 / 调用**：不查询实际表；Array等class分支语义可在该位false时仍存在。

### `Object.isArray` (`src/core/object.zig:3143`)

- **签名**：`pub inline fn isArray(self: *const Object) bool`。
- **作用**：按class判断是否内建Array。
- **实现**：class_id==class.ids.array。
- **所有权 / 错误 / 调用**：不解包Proxy，不执行ECMAScript IsArray的完整递归算法。

### `Object.supportsPlainNamedPropertyStorage` (`src/core/object.zig:3147`)

- **签名**：`inline fn supportsPlainNamedPropertyStorage(self: *const Object) bool`。
- **作用**：判断当前布局是否支持普通命名属性存储路径。
- **实现**：非Array返回true；Array仅在非fast_array、payload_kind ordinary且arrayArm.capacity为0时true。
- **所有权 / 错误 / 调用**：不是判断整个对象是否ordinary，也不代表没有exotic方法；Array特例用于无dense buffer的ordinary payload布局。

### `Object.isProxy` (`src/core/object.zig:3157`)

- **签名**：`pub inline fn isProxy(self: *const Object) bool`。
- **作用**：按class判断Proxy。
- **实现**：class_id==class.ids.proxy。
- **所有权 / 错误 / 调用**：不判断是否revoked或是否可调用。

### `Object.isGlobal` (`src/core/object.zig:3163`)

- **签名**：`pub inline fn isGlobal(self: *const Object) bool`。
- **作用**：按class判断global对象身份。
- **实现**：class_id==class.ids.global_object。
- **所有权 / 错误 / 调用**：不查询RealmContext是否仍存在或已销毁。

### `Object.hasPropertyStorage` (`src/core/object.zig:3167`)

- **签名**：`pub inline fn hasPropertyStorage(self: *const Object) bool`。
- **作用**：检查property指针是否为无存储哨兵。
- **实现**：prop_values!=emptyPropertyStorageBase()。
- **所有权 / 错误 / 调用**：不等于有活属性，也不查prop_count或分配成员资格。

### `Object.hasSlots2Layout` (`src/core/object.zig:3171`)

- **签名**：`pub inline fn hasSlots2Layout(self: *const Object) bool`。
- **作用**：查询对象分配布局标志。
- **实现**：返回flags.slots2_layout。
- **所有权 / 错误 / 调用**：属性已spill仍可为true，不能代替propertyStorageIsInline。

### `Object.propertyStorageIsInline` (`src/core/object.zig:3175`)

- **签名**：`pub inline fn propertyStorageIsInline(self: *const Object) bool`。
- **作用**：判断当前property指针仍指向slots2尾部。
- **实现**：hasSlots2Layout且prop_values等于trailingPropertyStorageBase(self)。
- **所有权 / 错误 / 调用**：短路避免非slots2进入尾部助手；不查属性数或是否已装payload。

### `Object.needsSlowPropertyAccess` (`src/core/object.zig:3179`)

- **签名**：`pub inline fn needsSlowPropertyAccess(self: *const Object) bool`。
- **作用**：取得class及exotic标志决定的慢属性访问分类。
- **实现**：调用classNeedsSlowPropertyAccess(class_id,flags.has_exotic_methods)。
- **所有权 / 错误 / 调用**：不实际查属性，也不验证具体key能否命中快速路径。

### `Object.exoticMethods` (`src/core/object.zig:3183`)

- **签名**：`pub fn exoticMethods(self: *const Object, rt: *const JSRuntime) ?*const ExoticMethods`。
- **作用**：借用对象当前可用的exotic方法表。
- **实现**：flag false返回null；优先exoticMethodsForClassId，其次rt.classes.record(class_id)的exotic_methods，缺失均null，存在转换为ExoticMethods。
- **所有权 / 错误 / 调用**：不创建或复制表，不保证每个hook非null；依赖class注册的指针类型与生命周期，生产标准class可通过其它分支实现语义。

### `Object.installClassExoticMethods` (`src/core/object.zig:3192`)

- **签名**：`pub fn installClassExoticMethods(rt: *JSRuntime, class_id: class.ClassId, methods: *const ExoticMethods) void`。
- **作用**：仅测试：给标准或动态 class 安装 exotic 表。
- **实现**：非测试构建直接 @compileError；class_id 小于 class.ids.init_count 时写入文件级 test_standard_exotic_methods[class_id] 并返回；否则若 class_id 落在 rt.classes.records 范围内，置该 record 的 has_exotic=true 并把 methods 存入 exotic_methods（@ptrCast 成 opaque）。越界 class_id 静默无操作。
- **所有权 / 错误 / 调用**：只存借用指针，不复制表，调用方须保证 methods 的存活长于所有使用它的对象；标准 class 分支写的是进程级静态数组，不随 runtime 销毁重置。此函数也不设置任何对象的 flags.has_exotic_methods。


### `Object.iteratorTarget` (`src/core/object.zig:3204`)

- **签名**：`pub fn iteratorTarget(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的target值。
- **实现**：iteratorPayloadConst存在则返回payload.target，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。调用方 `exec/iterator_ops.zig:1509`、`exec/string_ops.zig:2191`，两处都把 null 变成 `error.TypeError`。

### `Object.iteratorDataSlot` (`src/core/object.zig:3209`)

- **签名**：`pub fn iteratorDataSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的data可变槽。
- **实现**：iteratorPayload存在返回&payload.data；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorData` (`src/core/object.zig:3215`)

- **签名**：`pub fn iteratorData(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的data值。
- **实现**：iteratorPayloadConst存在则返回payload.data，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。调用方 `exec/iterator_ops.zig:2836`/`:2903`/`:3044`、`exec/string_ops.zig:3202`，null 表示「内层迭代器已放掉」，各自走结束分支而不是报错。

### `Object.iteratorNextSlot` (`src/core/object.zig:3220`)

- **签名**：`pub fn iteratorNextSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的next可变槽。
- **实现**：iteratorPayload存在返回&payload.next；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorNext` (`src/core/object.zig:3226`)

- **签名**：`pub fn iteratorNext(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的next值。
- **实现**：iteratorPayloadConst存在则返回payload.next，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。调用方 7 处，主要是 `exec/iterator_ops.zig:255`、`exec/call_runtime.zig:4376`（null → `error.TypeError`）与 `exec/promise_ops.zig:3327`、`exec/iterator_ops.zig:3299`（null 时现取属性补上）。

### `Object.iteratorCallbackSlot` (`src/core/object.zig:3231`)

- **签名**：`pub fn iteratorCallbackSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的callback可变槽。
- **实现**：iteratorPayload存在返回&payload.callback；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorCallback` (`src/core/object.zig:3237`)

- **签名**：`pub fn iteratorCallback(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的callback值。
- **实现**：iteratorPayloadConst存在则返回payload.callback，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。调用方 `exec/iterator_ops.zig:2610`、`:2890`，null 一律 `error.TypeError`。

### `Object.iteratorInnerNextSlot` (`src/core/object.zig:3242`)

- **签名**：`pub fn iteratorInnerNextSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的inner_next可变槽。
- **实现**：iteratorPayload存在返回&payload.inner_next；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorInnerNext` (`src/core/object.zig:3248`)

- **签名**：`pub fn iteratorInnerNext(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的inner_next值。
- **实现**：iteratorPayloadConst存在则返回payload.inner_next，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。调用方 `exec/iterator_ops.zig:2837`、`:2904`，null 一律 `error.TypeError`。

### `Object.iteratorZipNextsSlot` (`src/core/object.zig:3253`)

- **签名**：`pub fn iteratorZipNextsSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的zip_nexts可变槽。
- **实现**：iteratorPayload存在返回&payload.zip_nexts；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorZipNexts` (`src/core/object.zig:3259`)

- **签名**：`pub fn iteratorZipNexts(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的zip_nexts值。
- **实现**：iteratorPayloadConst存在则返回payload.zip_nexts，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。树内唯一调用方 `exec/iterator_ops.zig:2679`（null → `error.TypeError`）。

### `Object.iteratorZipPadsSlot` (`src/core/object.zig:3264`)

- **签名**：`pub fn iteratorZipPadsSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的zip_pads可变槽。
- **实现**：iteratorPayload存在返回&payload.zip_pads；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorZipPads` (`src/core/object.zig:3270`)

- **签名**：`pub fn iteratorZipPads(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的zip_pads值。
- **实现**：iteratorPayloadConst存在则返回payload.zip_pads，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。树内唯一调用方 `exec/iterator_ops.zig:2681`（null → `error.TypeError`）。

### `Object.iteratorZipKeysSlot` (`src/core/object.zig:3275`)

- **签名**：`pub fn iteratorZipKeysSlot(self: *Object) *?JSValue`。
- **作用**：借用iterator的zip_keys可变槽。
- **实现**：iteratorPayload存在返回&payload.zip_keys；否则断言class_payload_kind为iterator后unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不执行GC写屏障或清理旧值；写入强边的调用者须遵守屏障协议。槽指针不得越过payload生命周期。

### `Object.iteratorZipKeys` (`src/core/object.zig:3281`)

- **签名**：`pub fn iteratorZipKeys(self: *const Object) ?JSValue`。
- **作用**：查询iterator payload的zip_keys值。
- **实现**：iteratorPayloadConst存在则返回payload.zip_keys，否则null。
- **所有权 / 错误 / 调用**：无分配、无 error set、不 retain：返回的是 `IteratorPayload` 借用的 `?JSValue`，存活靠 `IteratorPayload.traceChildEdges` 的对应边（`destroy` 只把槽置 null），调用方不得释放。`class_payload_kind` 非 iterator 与字段未设置都返回 null，二者不可区分。树内唯一调用方 `exec/iterator_ops.zig:2684`（null → `error.TypeError`）。

### `Object.iteratorAtomKeysSlot` (`src/core/object.zig:3286`)

- **签名**：`pub fn iteratorAtomKeysSlot(self: *Object) *[]atom.Atom`。
- **作用**：借用iterator的atom_keys字段。
- **实现**：payload存在返回字段地址，否则断言iterator kind并unreachable。
- **所有权 / 错误 / 调用**：不执行索引/模式范围验证或关联字段更新；atom_keys槽替换也不会自动释放旧数组。调用者负责完整状态合同。

### `Object.iteratorAtomKeys` (`src/core/object.zig:3292`)

- **签名**：`pub fn iteratorAtomKeys(self: *const Object) []const atom.Atom`。
- **作用**：借用iterator的atom键数组。
- **实现**：payload存在返回atom_keys，否则空const slice。
- **所有权 / 错误 / 调用**：不复制或retain atoms，不保证迭代期间底层数组不会被其它调用替换；缺失payload不是错误。

### `Object.iteratorIndexSlot` (`src/core/object.zig:3297`)

- **签名**：`pub fn iteratorIndexSlot(self: *Object) *usize`。
- **作用**：借用iterator的index字段。
- **实现**：payload存在返回字段地址，否则断言iterator kind并unreachable。
- **所有权 / 错误 / 调用**：不执行索引/模式范围验证，也不联动更新 iterator 的其它字段；裸写不执行屏障。调用者负责完整状态合同。

### `Object.iteratorKindSlot` (`src/core/object.zig:3303`)

- **签名**：`pub fn iteratorKindSlot(self: *Object) *u8`。
- **作用**：借用iterator的kind字段。
- **实现**：payload存在返回字段地址，否则断言iterator kind并unreachable。
- **所有权 / 错误 / 调用**：不执行索引/模式范围验证，也不联动更新 iterator 的其它字段；裸写不执行屏障。调用者负责完整状态合同。

### `Object.iteratorZipAliveSlot` (`src/core/object.zig:3309`)

- **签名**：`pub fn iteratorZipAliveSlot(self: *Object) *usize`。
- **作用**：借用iterator的zip_alive字段。
- **实现**：payload存在返回字段地址，否则断言iterator kind并unreachable。
- **所有权 / 错误 / 调用**：不执行索引/模式范围验证，也不联动更新 iterator 的其它字段；裸写不执行屏障。调用者负责完整状态合同。

### `Object.iteratorZipModeSlot` (`src/core/object.zig:3315`)

- **签名**：`pub fn iteratorZipModeSlot(self: *Object) *u8`。
- **作用**：借用iterator的zip_mode字段。
- **实现**：payload存在返回字段地址，否则断言iterator kind并unreachable。
- **所有权 / 错误 / 调用**：不执行索引/模式范围验证，也不联动更新 iterator 的其它字段；裸写不执行屏障。调用者负责完整状态合同。

### `Object.iteratorZipStateSlot` (`src/core/object.zig:3321`)

- **签名**：`pub fn iteratorZipStateSlot(self: *Object) *u8`。
- **作用**：借用iterator的zip_state字段。
- **实现**：payload存在返回字段地址，否则断言iterator kind并unreachable。
- **所有权 / 错误 / 调用**：不执行索引/模式范围验证，也不联动更新 iterator 的其它字段；裸写不执行屏障。调用者负责完整状态合同。

### `Object.collectionEntriesSlot` (`src/core/object.zig:3328`)

- **签名**：`pub fn collectionEntriesSlot(self: *Object) *[]CollectionEntry`。
- **作用**：借用collection的entries可变字段。
- **实现**：collectionPayload存在返回字段地址，否则断言collection kind并unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不联动更新entries/capacity/buckets/active_count，其一致性由调用者维护；裸写不自动执行GC屏障。

### `Object.collectionEntries` (`src/core/object.zig:3334`)

- **签名**：`pub fn collectionEntries(self: *const Object) []CollectionEntry`。
- **作用**：查询collection的entries。
- **实现**：collectionPayloadConst存在返回字段，否则空slice。
- **所有权 / 错误 / 调用**：不计算或验证统计；entries和bucket_heads返回可变元素slice，即使self为const也不保证底层只读。数组借用可被扩容替换。

### `Object.collectionEntriesCapacitySlot` (`src/core/object.zig:3339`)

- **签名**：`pub fn collectionEntriesCapacitySlot(self: *Object) *usize`。
- **作用**：借用collection的entries_capacity可变字段。
- **实现**：collectionPayload存在返回字段地址，否则断言collection kind并unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不联动更新entries/capacity/buckets/active_count，其一致性由调用者维护；裸写不自动执行GC屏障。

### `Object.collectionEntriesCapacity` (`src/core/object.zig:3345`)

- **签名**：`pub fn collectionEntriesCapacity(self: *const Object) usize`。
- **作用**：查询collection的entries_capacity。
- **实现**：collectionPayloadConst存在返回字段，否则0。
- **所有权 / 错误 / 调用**：读取存储的计数，不扫描元素重新计算，不分配。

### `Object.collectionBucketHeadsSlot` (`src/core/object.zig:3350`)

- **签名**：`pub fn collectionBucketHeadsSlot(self: *Object) *[]usize`。
- **作用**：借用collection的bucket_heads可变字段。
- **实现**：collectionPayload存在返回字段地址，否则断言collection kind并unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不联动更新entries/capacity/buckets/active_count，其一致性由调用者维护；裸写不自动执行GC屏障。

### `Object.collectionBucketHeads` (`src/core/object.zig:3356`)

- **签名**：`pub fn collectionBucketHeads(self: *const Object) []usize`。
- **作用**：查询collection的bucket_heads。
- **实现**：collectionPayloadConst存在返回字段，否则空slice。
- **所有权 / 错误 / 调用**：不计算或验证统计；entries和bucket_heads返回可变元素slice，即使self为const也不保证底层只读。数组借用可被扩容替换。

### `Object.collectionActiveCountSlot` (`src/core/object.zig:3361`)

- **签名**：`pub fn collectionActiveCountSlot(self: *Object) *usize`。
- **作用**：借用collection的active_count可变字段。
- **实现**：collectionPayload存在返回字段地址，否则断言collection kind并unreachable。
- **所有权 / 错误 / 调用**：不创建payload，不联动更新entries/capacity/buckets/active_count，其一致性由调用者维护；裸写不自动执行GC屏障。

### `Object.collectionActiveCount` (`src/core/object.zig:3367`)

- **签名**：`pub fn collectionActiveCount(self: *const Object) usize`。
- **作用**：查询collection的active_count。
- **实现**：collectionPayloadConst存在返回字段，否则0。
- **所有权 / 错误 / 调用**：读取存储的计数，不扫描元素重新计算，不分配。

### `Object.retainCollectionCursor` (`src/core/object.zig:3375`)

- **签名**：`pub fn retainCollectionCursor(self: *Object) void`。
- **作用**：增加collection上的活跃游标计数。
- **实现**：payload缺失无操作，否则live_cursors普通加一。
- **所有权 / 错误 / 调用**：不是宿主GC pin、不绑定特定entry或保留数组地址；调用者须配对release并处理计数边界。

### `Object.releaseCollectionCursor` (`src/core/object.zig:3386`)

- **签名**：`pub fn releaseCollectionCursor(self: *Object) void`。
- **作用**：归还一份collection游标计数。
- **实现**：payload缺失返回；live_cursors非零才减一。
- **所有权 / 错误 / 调用**：零时无操作，不报重复release；不释放entry或数组，不能等同具体record析构。

### `Object.collectionLiveCursors` (`src/core/object.zig:3391`)

- **签名**：`pub fn collectionLiveCursors(self: *const Object) usize`。
- **作用**：读取collection的活跃游标计数。
- **实现**：payload存在返回live_cursors，否则0。
- **所有权 / 错误 / 调用**：不枚举实际iterator对象，也不证明没有其它引用。

### `Object.retainCollectionIteratorCursor` (`src/core/object.zig:3400`)

- **签名**：`pub fn retainCollectionIteratorCursor(self: *Object) void`。
- **作用**：为已开始使用的Map/Set iterator登记一次游标持有。
- **实现**：缺iterator payload、已held、非map/set iterator、target为空或非Object均返回；否则target_object.retainCollectionCursor后置held=true。
- **所有权 / 错误 / 调用**：不分配或GC pin；target的retain若因缺collection payload无操作，held仍置true，所以合法target类型是调用合同，不是这里完整验证。

### `Object.detachCollectionIteratorTarget` (`src/core/object.zig:3414`)

- **签名**：`pub fn detachCollectionIteratorTarget(self: *Object, _: *JSRuntime) void`。
- **作用**：归还iterator游标计数并断开target。
- **实现**：payload缺失或target为空返回；releaseIteratorCollectionCursor后target=null。
- **所有权 / 错误 / 调用**：rt当前未用，不执行RC free。target本就为空时不单独修复held；正常配对由游标协议保证。

### `Object.ensureCollectionEntryCapacity` (`src/core/object.zig:3421`)

- **签名**：`pub fn ensureCollectionEntryCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void`。
- **作用**：确保entries数组至少拥有请求容量。
- **实现**：当前entries_capacity>=min_capacity则返回；否则从已有容量或有效len起步，至少8，反复乘2。allocRuntime(CollectionEntry)新buffer，复制有效项、替换slice但保持len并写capacity；按旧capacity释放完整旧分配，旧capacity为0但len非0时按旧slice释放。
- **所有权 / 错误 / 调用**：OOM在替换前传播；容量乘2是普通算术，不是checked增长。新余量未初始化，不改变条目语义计数或weak身份引用；借用的旧数组指针在成功后失效。

### `Object.appendCollectionEntryUnindexed` (`src/core/object.zig:3444`)

- **签名**：`pub fn appendCollectionEntryUnindexed(self: *Object, rt: *JSRuntime, entry: CollectionEntry) !usize`。
- **作用**：向强collection entries追加记录但不更新hash索引。
- **实现**：保存旧len作index，ensure容量后重新取slot，扩slice并安装entry，分别对key/value执行generationalBarrier，返回index。
- **所有权 / 错误 / 调用**：不更新active_count、bucket_heads或判重；这些由调用方维护。扩容可能改变backing地址；entry是浅复制，屏障是owner Object到key/value。

### `Object.clearCollectionIndex` (`src/core/object.zig:3460`)

- **签名**：`pub fn clearCollectionIndex(self: *Object, rt: *JSRuntime) void`。
- **作用**：释放collection的bucket head索引数组。
- **实现**：借用bucket slot，先置空，再对非空旧slice用memory.free(usize)。
- **所有权 / 错误 / 调用**：不清entries/weak_entries或active_count，不直接重建hash索引。

### `Object.weakCollectionEntriesSlot` (`src/core/object.zig:3467`)

- **签名**：`pub fn weakCollectionEntriesSlot(self: *Object) *[]WeakCollectionEntry`。
- **作用**：借用collection weak_entries的可变slice槽。
- **实现**：payload存在返回字段地址，否则断言collection kind并unreachable。
- **所有权 / 错误 / 调用**：不创建payload、分配数组或管理weak identity引用；调用者负责容量及identity合同。

### `Object.weakCollectionEntries` (`src/core/object.zig:3473`)

- **签名**：`pub fn weakCollectionEntries(self: *const Object) []WeakCollectionEntry`。
- **作用**：查询collection当前weak_entries。
- **实现**：有payload返回slice，否则空slice。
- **所有权 / 错误 / 调用**：self const仍返回可变元素，不深复制；扩容或压缩可能使保存的元素指针失效。

### `Object.ensureWeakCollectionEntryCapacity` (`src/core/object.zig:3478`)

- **签名**：`pub fn ensureWeakCollectionEntryCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void`。
- **作用**：确保weak_entries数组至少拥有请求容量。
- **实现**：当前weak_entries_capacity>=min_capacity则返回；否则从已有容量或有效len起步，至少4，反复乘2。allocRuntime(WeakCollectionEntry)新buffer，复制有效项、替换slice但保持len并写capacity；按旧capacity释放完整旧分配，旧capacity为0但len非0时按旧slice释放。
- **所有权 / 错误 / 调用**：OOM在替换前传播；容量乘2是普通算术，不是checked增长。新余量未初始化，不改变条目语义计数或weak身份引用；借用的旧数组指针在成功后失效。

### `Object.finalizationRegistryCleanupCallbackSlot` (`src/core/object.zig:3504`)

- **签名**：`pub fn finalizationRegistryCleanupCallbackSlot(self: *Object) *?JSValue`。
- **作用**：借用FR cleanup callback可选值槽。
- **实现**：有FR payload返回字段地址，否则断言对应kind后unreachable。
- **所有权 / 错误 / 调用**：裸槽写入不自动校验可调用性或执行屏障；由安装调用方负责。

### `Object.finalizationRegistryCleanupCallback` (`src/core/object.zig:3510`)

- **签名**：`pub fn finalizationRegistryCleanupCallback(self: *const Object) ?JSValue`。
- **作用**：查询FR cleanup callback值。
- **实现**：有payload返回cleanup_callback，否则null。
- **所有权 / 错误 / 调用**：不调用回调，也不创建默认函数。

### `Object.finalizationRegistryRealmContext` (`src/core/object.zig:3515`)

- **签名**：`pub fn finalizationRegistryRealmContext(self: *const Object) ?*context_mod.RealmContext`。
- **作用**：借用FR payload拥有的RealmContext。
- **实现**：无payload返回null，否则payload.realm.borrow()。
- **所有权 / 错误 / 调用**：不增加RealmRef引用，不从当前执行context推断realm。

### `Object.finalizationRegistryCellsSlot` (`src/core/object.zig:3520`)

- **签名**：`pub fn finalizationRegistryCellsSlot(self: *Object) *[]FinalizationRegistryCell`。
- **作用**：借用FR cells的可变slice槽。
- **实现**：有payload返回&cells，否则断言并unreachable。
- **所有权 / 错误 / 调用**：不调整cells_capacity、job reservations或weak identity计数，直接修改须保持全部协议。

### `Object.finalizationRegistryCells` (`src/core/object.zig:3526`)

- **签名**：`pub fn finalizationRegistryCells(self: *const Object) []FinalizationRegistryCell`。
- **作用**：查询FR cell数组。
- **实现**：有payload返回cells，否则空slice。
- **所有权 / 错误 / 调用**：返回可变元素，即使self const；不筛选active/pending/queued，借用受数组替换影响。

### `Object.pendingFinalizationCellCountForTest` (`src/core/object.zig:3531`)

- **签名**：`pub fn pendingFinalizationCellCountForTest(self: *const Object) usize`。
- **作用**：测试：数 isPending 的 FR cell。
- **实现**：非测试构建直接 @compileError；无 FR payload 返回 0；否则遍历 payload.cells，对 isPending() 为真的 cell 累加计数并返回。
- **所有权 / 错误 / 调用**：不单独拥有堆；所有权在 Object/payload/Shape/runtime 侧表。


### `Object.unregisterFinalizationRegistryCells` (`src/core/object.zig:3541`)

- **签名**：`pub fn unregisterFinalizationRegistryCells(self: *Object, rt: *JSRuntime, token: JSValue) bool`。
- **作用**：移除具有匹配live unregister token的active注册cell。
- **实现**：断言FR class；weakIdentityFromValuePeek无identity或identity不live则false。稳定压缩cells，仅active且非空token identity相等者cell.destroy并标removed。缩短slice后有移除才prune空holder，返回removed。
- **所有权 / 错误 / 调用**：pending/queued不按该token移除；不新建identity、不缩capacity或调用cleanup callback。cell.destroy归还target/token identity以及active的job预留槽，held_value无需RC free。

### `Object.ensureFinalizationRegistryCellCapacity` (`src/core/object.zig:3569`)

- **签名**：`pub fn ensureFinalizationRegistryCellCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void`。
- **作用**：确保cells数组至少拥有请求容量。
- **实现**：当前cells_capacity>=min_capacity则返回；否则从已有容量或有效len起步，至少4，反复乘2。allocRuntime(FinalizationRegistryCell)新buffer，复制有效项、替换slice但保持len并写capacity；按旧capacity释放完整旧分配，旧capacity为0但len非0时按旧slice释放。
- **所有权 / 错误 / 调用**：OOM在替换前传播；容量乘2是普通算术，不是checked增长。新余量未初始化，不改变条目语义计数或weak身份引用；借用的旧数组指针在成功后失效。

### `Object.appendFinalizationRegistryCell` (`src/core/object.zig:3594`)

- **签名**：`pub fn appendFinalizationRegistryCell( self: *Object, rt: *JSRuntime, target: JSValue, held_value: JSValue, unregister_token: JSValue, ) !void`。
- **作用**：追加带弱 target/token 身份及强 held_value 的 FR 注册记录。
- **实现**：断言 FR class，以 ValueRootFrame 包住三个输入值；取得 target/token identity 后登记 borrowed holder（配 errdefer 撤销），确保 cells 容量，再扩有效长度、retain 两个非空 identity，并预留一个 cleanup job 槽。安装 cell 后对 held_value 做 owner 屏障返回。原先末尾还有一次重复的 registerBorrowedReferenceHolder（cell 已装好、屏障已打之后），既无 errdefer 覆盖也无新增效果，已删除。
- **所有权 / 错误 / 调用**：错误按已到达的步骤归还 job 预留槽和 identity retain、恢复有效长度，并撤销本次新加的 holder。已扩大的容量及先前创建的 weak identity 不在这些 errdefer 中撤销。根帧列出的是三个输入值，不含 self；调用方负责 registry 的存活及参数语义验证。target/token 不作为 cell 的强边。retain/releaseWeakIdentity 对 object identity 无操作，仅 symbol atom 维护弱引用计数。

### `Object.stdFileSlot` (`src/core/object.zig:3649`)

- **签名**：`pub fn stdFileSlot(self: *Object) *?*std.c.FILE`。
- **作用**：借用 payload 的 file 可变字段槽。
- **实现**：stdFilePayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.stdFileIsPopenSlot` (`src/core/object.zig:3655`)

- **签名**：`pub fn stdFileIsPopenSlot(self: *Object) *bool`。
- **作用**：借用 payload 的 is_popen 可变字段槽。
- **实现**：stdFilePayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.stdFileIsStdioSlot` (`src/core/object.zig:3661`)

- **签名**：`pub fn stdFileIsStdioSlot(self: *Object) *bool`。
- **作用**：借用 payload 的 is_stdio 可变字段槽。
- **实现**：stdFilePayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.disposableStackDisposedSlot` (`src/core/object.zig:3667`)

- **签名**：`pub fn disposableStackDisposedSlot(self: *Object) *bool`。
- **作用**：借用 payload 的 disposed 可变字段槽。
- **实现**：disposableStackPayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.disposableStackDisposed` (`src/core/object.zig:3673`)

- **签名**：`pub fn disposableStackDisposed(self: *const Object) bool`。
- **作用**：查询 stack 的 disposed 标志。
- **实现**：有 disposable payload 则返回 disposed，否则 false。
- **所有权 / 错误 / 调用**：不判断资源列表是否为空，也不执行资源释放。

### `Object.appendDisposableResource` (`src/core/object.zig:3678`)

- **签名**：`pub fn appendDisposableResource( self: *Object, rt: *JSRuntime, resource_value: JSValue, method: JSValue, kind: DisposableResourceKind, hint: DisposalHint, method_kind: DisposableMethodKind, ) !void`。
- **作用**：向 disposable stack 追加一条资源及其处理方式。
- **实现**：必须已有 payload；len 等于 capacity 时从 4 起或翻倍创建 GC payload slice cell，复制有效记录、安装新 slice/capacity，并 remember owner。随后扩 len，写 value/method/kind/hint/method_kind，分别屏障两个值。
- **所有权 / 错误 / 调用**：分配失败发生在新列表安装前；旧列表 cell 由 GC 回收，不手动 free。本函数没有显式输入根帧，不检查 disposed 或 method 可调用性；调用方负责相应合同。扩容后的旧元素借用不应继续作为当前列表使用。

### `Object.disposableStackHasAsyncHint` (`src/core/object.zig:3720`)

- **签名**：`pub fn disposableStackHasAsyncHint(self: *const Object) bool`。
- **作用**：判断当前资源列表是否存在 async hint。
- **实现**：无 payload 则 false；顺序扫描 resources，首次 hint==async 返回 true，否则 false。
- **所有权 / 错误 / 调用**：不检查 disposed、异步 capability 或实际 method 是否返回 Promise。

### `Object.disposableStackAsyncResolveSlot` (`src/core/object.zig:3728`)

- **签名**：`pub fn disposableStackAsyncResolveSlot(self: *Object) *?JSValue`。
- **作用**：借用 payload 的 async_dispose_resolve 可变字段槽。
- **实现**：disposableStackPayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.disposableStackAsyncRejectSlot` (`src/core/object.zig:3734`)

- **签名**：`pub fn disposableStackAsyncRejectSlot(self: *Object) *?JSValue`。
- **作用**：借用 payload 的 async_dispose_reject 可变字段槽。
- **实现**：disposableStackPayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.disposableStackAsyncErrorSlot` (`src/core/object.zig:3740`)

- **签名**：`pub fn disposableStackAsyncErrorSlot(self: *Object) *?JSValue`。
- **作用**：借用 payload 的 async_dispose_error 可变字段槽。
- **实现**：disposableStackPayload() 成功则返回字段地址，否则断言相应 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload。直接写槽不会自动执行写屏障、释放旧资源或维护其他状态，调用方负责相关协议。

### `Object.clearDisposableStackAsyncCapability` (`src/core/object.zig:3746`)

- **签名**：`pub fn clearDisposableStackAsyncCapability(self: *Object, _: *JSRuntime) void`。
- **作用**：清空异步 dispose 的 resolve、reject、error 字段。
- **实现**：有 payload 时依次置三个 optional 值为 null；没有则无操作。
- **所有权 / 错误 / 调用**：不调用回调、不释放资源列表、不改变 disposed；rt 未使用，无 RC release。

### `Object.popDisposableResource` (`src/core/object.zig:3754`)

- **签名**：`pub fn popDisposableResource(self: *Object) ?DisposableResource`。
- **作用**：按 LIFO 取出并移除最后一条资源记录。
- **实现**：无 payload 或 resources 为空返回 null；否则保存最后记录，缩短有效 slice 后按值返回。
- **所有权 / 错误 / 调用**：不调用 dispose method、不缩 capacity、不清底层尾槽。返回记录的后续处理和存活保护由调用方负责。

### `Object.moveDisposableResourcesTo` (`src/core/object.zig:3763`)

- **签名**：`pub fn moveDisposableResourcesTo(self: *Object, rt: *JSRuntime, target: *Object) !void`。
- **作用**：把资源列表及容量转交给空 target stack。
- **实现**：两边必须有 disposable payload，断言 target 的 len 和 capacity 均为零；复制 slice/capacity 后清空 source 的对应字段。转移容量非零时 remember target owner。
- **所有权 / 错误 / 调用**：不分配或复制元素，当前函数没有返回 error 的分支，虽签名为 !void。不转移 disposed、异步 capability 等其他字段，不自动标记 source 已 disposed。

### `Object.setVarRefValue` (`src/core/object.zig:3783`)

- **签名**：`pub fn setVarRefValue(self: *Object, rt: *JSRuntime, next_value: JSValue) !void`。
- **作用**：写入 Object 的 var_ref payload.value 并执行 owner 屏障。
- **实现**：借用 varRefValueSlot，先写 next_value，再以 self 的 header 和值的 cycleMarkHeader 调用 generationalBarrier。
- **所有权 / 错误 / 调用**：要求已有正确 payload；不是 VarRef cell 的同名 setter。当前没有 fallible 操作，不 retain/release 值。

### `Object.setOptionalValueSlot` (`src/core/object.zig:3792`)

- **签名**：`pub fn setOptionalValueSlot(self: *Object, rt: *JSRuntime, slot: *?JSValue, next_value: ?JSValue) !void`。
- **作用**：写入 optional 值槽并对非空值执行 self 的 owner 屏障。
- **实现**：先赋值 slot，next_value 非空时调用 generationalBarrier(self.gcHeader(), stored.cycleMarkHeader())。
- **所有权 / 错误 / 调用**：slot 必须属于以 self 为追踪 owner 的存储；函数不验证归属。写 null 不执行屏障，无分配或实际 error 分支。

### `Object.clearOptionalValueSlot` (`src/core/object.zig:3801`)

- **签名**：`pub fn clearOptionalValueSlot(self: *Object, _: *JSRuntime, slot: *?JSValue) void`。
- **作用**：把给定 optional 值槽置空。
- **实现**：直接 slot.*=null；self 与 rt 均未使用。
- **所有权 / 错误 / 调用**：不检查槽归属，不调用回调、RC release 或写屏障。

### `Object.takeOptionalValueSlot` (`src/core/object.zig:3806`)

- **签名**：`pub fn takeOptionalValueSlot(self: *Object, slot: *?JSValue) ?JSValue`。
- **作用**：取走 optional 值并清空原槽。
- **实现**：保存 slot.*，置 null 后返回旧值；self 未使用。
- **所有权 / 错误 / 调用**：不验证槽归属、不执行 GC pin 或 RC retain/release；后续存活保护由接收者负责。

### `Object.setPromiseResult` (`src/core/object.zig:3813`)

- **签名**：`pub fn setPromiseResult(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 promiseResultSlot 所指 optional 值。
- **实现**：取得对应槽后委托 setOptionalValueSlot，先写值，对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：要求槽对应 payload 已存在；不推进 Promise 状态、不排 reaction job，也不校验值的语义。当前委托实现没有实际 error 分支。

### `Object.setPromiseReactionCallback` (`src/core/object.zig:3817`)

- **签名**：`pub fn setPromiseReactionCallback(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 promiseReactionCallbackSlot 所指 optional 值。
- **实现**：取得对应槽后委托 setOptionalValueSlot，先写值，对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：要求槽对应 payload 已存在；不推进 Promise 状态、不排 reaction job，也不校验值的语义。当前委托实现没有实际 error 分支。

### `Object.setPromiseReactionArg` (`src/core/object.zig:3821`)

- **签名**：`pub fn setPromiseReactionArg(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 promiseReactionArgSlot 所指 optional 值。
- **实现**：取得对应槽后委托 setOptionalValueSlot，先写值，对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：要求槽对应 payload 已存在；不推进 Promise 状态、不排 reaction job，也不校验值的语义。当前委托实现没有实际 error 分支。

### `Object.setFunctionPromiseCapabilitySlot` (`src/core/object.zig:3825`)

- **签名**：`pub fn setFunctionPromiseCapabilitySlot(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_capability_slot。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.setFunctionPromiseResolvingTarget` (`src/core/object.zig:3829`)

- **签名**：`pub fn setFunctionPromiseResolvingTarget(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_resolving_target。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.setFunctionPromiseResolvingState` (`src/core/object.zig:3833`)

- **签名**：`pub fn setFunctionPromiseResolvingState(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_resolving_state。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.setFunctionPromiseCombinatorState` (`src/core/object.zig:3837`)

- **签名**：`pub fn setFunctionPromiseCombinatorState(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_combinator_state。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.setFunctionPromiseFinallyPayload` (`src/core/object.zig:3841`)

- **签名**：`pub fn setFunctionPromiseFinallyPayload(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_finally_payload。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.setFunctionPromiseFinallyCallback` (`src/core/object.zig:3845`)

- **签名**：`pub fn setFunctionPromiseFinallyCallback(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_finally_callback。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.setFunctionPromiseFinallyConstructor` (`src/core/object.zig:3849`)

- **签名**：`pub fn setFunctionPromiseFinallyConstructor(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 function rare payload 的 promise_finally_constructor。
- **实现**：先 ensureFunctionRarePayload，再通过 setOptionalValueSlot 写字段并对非空值执行 self 的 owner 屏障。
- **所有权 / 错误 / 调用**：即使 next_value 为 null 也先确保 rare payload；该步骤可能分配并失败。失败前不写目标字段；本 setter 不调用存入的函数或执行 Promise 算法。

### `Object.varRefValueSlot` (`src/core/object.zig:3853`)

- **签名**：`pub fn varRefValueSlot(self: *Object) *?JSValue`。
- **作用**：借用 Object var_ref payload 的 value 字段槽。
- **实现**：varRefPayload 成功返回字段地址，否则断言 kind 为 var_ref 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接改槽不自动执行屏障或实现 const、TDZ、删除等语言语义。

### `Object.varRefValue` (`src/core/object.zig:3859`)

- **签名**：`pub fn varRefValue(self: *const Object) ?JSValue`。
- **作用**：查询 Object var_ref payload 中的 optional value。
- **实现**：有 payload 返回 value，否则 null。
- **所有权 / 错误 / 调用**：不创建 payload，也不执行语言层 TDZ 或 const 检查。

### `Object.varRefIsConstSlot` (`src/core/object.zig:3864`)

- **签名**：`pub fn varRefIsConstSlot(self: *Object) *bool`。
- **作用**：借用 Object var_ref payload 的 is_const 字段槽。
- **实现**：varRefPayload 成功返回字段地址，否则断言 kind 为 var_ref 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接改槽不自动执行屏障或实现 const、TDZ、删除等语言语义。

### `Object.varRefIsFunctionNameSlot` (`src/core/object.zig:3870`)

- **签名**：`pub fn varRefIsFunctionNameSlot(self: *Object) *bool`。
- **作用**：借用 Object var_ref payload 的 is_function_name 字段槽。
- **实现**：varRefPayload 成功返回字段地址，否则断言 kind 为 var_ref 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接改槽不自动执行屏障或实现 const、TDZ、删除等语言语义。

### `Object.varRefIsDeletableSlot` (`src/core/object.zig:3876`)

- **签名**：`pub fn varRefIsDeletableSlot(self: *Object) *bool`。
- **作用**：借用 Object var_ref payload 的 is_deletable 字段槽。
- **实现**：varRefPayload 成功返回字段地址，否则断言 kind 为 var_ref 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接改槽不自动执行屏障或实现 const、TDZ、删除等语言语义。

### `Object.ensureTypedArrayPayload` (`src/core/object.zig:3883`)

- **签名**：`pub fn ensureTypedArrayPayload(self: *Object, rt: *JSRuntime) !void`。
- **作用**：按需安装初始化的 TypedArrayPayload。
- **实现**：已有 typedArrayPayload 则返回；否则 createRuntime 分配并用默认值初始化，写 payload arm、设置 typed_array kind，标记需要 finalizer。
- **所有权 / 错误 / 调用**：分配失败前不安装；函数不检查 class 是否适合 view，也不销毁其他已有 kind 的 payload，调用方必须保证对象布局及使用协议。

### `Object.initTypedArrayView` (`src/core/object.zig:3899`)

- **签名**：`pub fn initTypedArrayView( self: *Object, rt: *JSRuntime, buffer_value: JSValue, byte_offset: usize, element_size: u32, fixed_length: ?u32, kind: u8, ) !void`。
- **作用**：建立 TypedArray/DataView 到 buffer 的强边和 buffer 的反向弱 view 链。
- **实现**：验证 buffer_value 是 ArrayBuffer/SharedArrayBuffer Object 且具有 buffer payload；确保 view payload，若有旧 backing 先 detachView，再通过 setOptionalValueSlot 安装 buffer 值与屏障，写 offset/element_size/fixed_length/kind，最后 attachView 更新缓存状态。
- **所有权 / 错误 / 调用**：不在此验证偏移对齐、越界或 detached 的语言层限制；输入保护由调用方负责，本函数未显式激活根帧。弱链不使 buffer 强持有 view；当前 tracing 实现不能把替换旧值描述为立即 RC 析构。

### `Object.byteStorage` (`src/core/object.zig:3932`)

- **签名**：`pub fn byteStorage(self: *const Object) []u8`。
- **作用**：借用 buffer 当前可见字节 slice。
- **实现**：有 buffer payload 返回 bytes，否则空 slice。
- **所有权 / 错误 / 调用**：self const 仍返回可变字节；不验证 detached/immutable，替换或释放 backing 后旧借用失效。

### `Object.installByteStorage` (`src/core/object.zig:3937`)

- **签名**：`pub fn installByteStorage(self: *Object, rt: *JSRuntime, bytes: []u8) !void`。
- **作用**：接管普通字节存储并刷新 linked views。
- **实现**：先 reportExternalAlloc(bytes.len)，成功后 releaseStorage 旧 backing，再安装 bytes 和计量 token，清 shared_store/inline_length，置 detached=false 并 updateViews。
- **所有权 / 错误 / 调用**：计量失败发生在释放旧存储前；不复制或初始化 bytes，后续普通释放路径以 runtime memory.free 归还，调用方须提供兼容分配。未校验 immutable/max_byte_length，也不支持假定与旧 backing 别名安全。

### `Object.installInlineByteStorage` (`src/core/object.zig:3953`)

- **签名**：`pub fn installInlineByteStorage(self: *Object, rt: *JSRuntime, byte_length: usize) !bool`。
- **作用**：把 buffer 存储切换到 payload 内联字节区。
- **实现**：长度超过 inline_storage_capacity 立即 false；否则要求 buffer payload，释放旧存储，登记 untracked 外部字节计量，清 shared/external 回调字段，设置 inline_length/bytes，置 detached=false、刷新 views，返回 true。
- **所有权 / 错误 / 调用**：不初始化内联字节内容；false 不改变旧存储。当前无实际 error 分支，虽签名为 !bool；不检查 immutable/max_byte_length。

### `Object.installExternalByteStorage` (`src/core/object.zig:3972`)

- **签名**：`pub fn installExternalByteStorage( self: *Object, rt: *JSRuntime, bytes: []u8, deinit_fn: ExternalByteStorageDeinit, context: ?*anyopaque, ) !void`。
- **作用**：接管带外部析构回调的字节存储。
- **实现**：先取得 external allocation token，再 releaseStorage，安装 bytes、token、deinit_fn/context，清 inline_length，置 detached=false 并刷新 views。
- **所有权 / 错误 / 调用**：releaseStorage 会清除旧 shared_store 和回调。计量失败保留旧 backing，未接管新 bytes；成功后由保存的回调释放，函数不复制数据。

### `Object.detachByteStorage` (`src/core/object.zig:3995`)

- **签名**：`pub fn detachByteStorage(self: *Object, rt: *JSRuntime) void`。
- **作用**：释放非共享 backing 并标记 detached。
- **实现**：必须有 buffer payload；shared_store 非空直接返回，否则 releaseStorage 后 detached=true。
- **所有权 / 错误 / 调用**：releaseStorage 会失效化 view 的缓存，但保留弱 view 链；这里不检查 immutable、detach key 或 class 的语言层限制。

### `Object.sharedByteStorageStore` (`src/core/object.zig:4006`)

- **签名**：`pub fn sharedByteStorageStore(self: *const Object) ?*SharedBufferStore`。
- **作用**：借用 buffer 的 SharedBufferStore 指针。
- **实现**：缺 buffer payload 返回 null，否则返回 shared_store。
- **所有权 / 错误 / 调用**：不 retain store、不延长其寿命。

### `Object.installSharedByteStorage` (`src/core/object.zig:4011`)

- **签名**：`pub fn installSharedByteStorage(self: *Object, rt: *JSRuntime, store: *SharedBufferStore) void`。
- **作用**：接管 SharedBufferStore 并安装其完整 bytes slice。
- **实现**：要求 buffer payload；releaseStorage 旧 backing 后设置 shared_store 和 store.bytes，清 inline_length/external_memory，置 detached=false 并 updateViews。
- **所有权 / 错误 / 调用**：函数不 retain store，调用方提供要转交的引用；不是复制 backing，也没有分配/error 分支。不要把与旧 store 相同的裸借用当作独立拥有的引用。

### `Object.setSharedByteStorageLength` (`src/core/object.zig:4029`)

- **签名**：`pub fn setSharedByteStorageLength(self: *Object, new_length: usize) !void`。
- **作用**：调整共享 backing 的可见前缀并刷新 view。
- **实现**：无 buffer payload 或无 shared_store 返回 TypeError；new_length 超过 store.bytes.len 返回 RangeError，否则安装该 store 的前缀并 updateViews。
- **所有权 / 错误 / 调用**：不分配或改变 store 身份/底层地址；也不检查单调增长、max_byte_length 或语言层 grow 条件，这些由上层负责。

### `Object.arrayBufferDetached` (`src/core/object.zig:4037`)

- **签名**：`pub fn arrayBufferDetached(self: *const Object) bool`。
- **作用**：查询 payload 的 detached 字段。
- **实现**：bufferPayloadConst() 成功则返回字段，否则返回 false。
- **所有权 / 错误 / 调用**：只读取存储字段，不执行构造、有效范围检查或状态变更。

### `Object.arrayBufferImmutableSlot` (`src/core/object.zig:4042`)

- **签名**：`pub fn arrayBufferImmutableSlot(self: *Object) *bool`。
- **作用**：借用 payload 的 immutable 可变槽。
- **实现**：bufferPayload() 成功返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：直接写槽不自动验证值、刷新 views 或执行 GC 屏障；调用方负责维护完整协议。

### `Object.arrayBufferImmutable` (`src/core/object.zig:4048`)

- **签名**：`pub fn arrayBufferImmutable(self: *const Object) bool`。
- **作用**：查询 payload 的 immutable 字段。
- **实现**：bufferPayloadConst() 成功则返回字段，否则返回 false。
- **所有权 / 错误 / 调用**：只读取存储字段，不执行构造、有效范围检查或状态变更。

### `Object.arrayBufferMaxByteLengthSlot` (`src/core/object.zig:4053`)

- **签名**：`pub fn arrayBufferMaxByteLengthSlot(self: *Object) *?usize`。
- **作用**：借用 payload 的 max_byte_length 可变槽。
- **实现**：bufferPayload() 成功返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：直接写槽不自动验证值、刷新 views 或执行 GC 屏障；调用方负责维护完整协议。

### `Object.arrayBufferMaxByteLength` (`src/core/object.zig:4059`)

- **签名**：`pub fn arrayBufferMaxByteLength(self: *const Object) ?usize`。
- **作用**：查询 payload 的 max_byte_length 字段。
- **实现**：bufferPayloadConst() 成功则返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：只读取存储字段，不执行构造、有效范围检查或状态变更。

### `Object.typedArrayBufferSlot` (`src/core/object.zig:4064`)

- **签名**：`pub fn typedArrayBufferSlot(self: *Object) *?JSValue`。
- **作用**：借用 payload 的 buffer 可变槽。
- **实现**：typedArrayPayload() 成功返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：直接写槽不自动验证值、刷新 views 或执行 GC 屏障；调用方负责维护完整协议。

### `Object.typedArrayBuffer` (`src/core/object.zig:4070`)

- **签名**：`pub fn typedArrayBuffer(self: *const Object) ?JSValue`。
- **作用**：查询 payload 的 buffer 字段。
- **实现**：typedArrayPayloadConst() 成功则返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：只读取存储字段，不执行构造、有效范围检查或状态变更。

### `Object.typedArrayByteOffset` (`src/core/object.zig:4075`)

- **签名**：`pub fn typedArrayByteOffset(self: *const Object) usize`。
- **作用**：查询 payload 的 byte_offset 字段。
- **实现**：typedArrayPayloadConst() 成功则返回字段，否则返回 0。
- **所有权 / 错误 / 调用**：只读取存储字段，不执行构造、有效范围检查或状态变更。

### `Object.typedArrayElementSizeSlot` (`src/core/object.zig:4080`)

- **签名**：`pub fn typedArrayElementSizeSlot(self: *Object) *u32`。
- **作用**：借用 view 或 native function 的 typed-array element_size 槽。
- **实现**：优先返回 typedArrayPayload 的字段；否则断言不是 bytecode function，再尝试 functionPayload.native.typed_array_element_size；都缺失则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload，直接写入不会自动刷新 view 缓存。支持 native constructor 元数据，不只支持 typed-array 实例。

### `Object.typedArrayElementSize` (`src/core/object.zig:4088`)

- **签名**：`pub fn typedArrayElementSize(self: *const Object) u32`。
- **作用**：查询 view 或 native function 的 typed-array element_size。
- **实现**：优先读取 typedArrayPayload；bytecode function 返回 0；否则读取 functionPayload.native.typed_array_element_size，缺失也返回 0。
- **所有权 / 错误 / 调用**：不验证字段含义或访问合法性，不分配。

### `Object.typedArrayFixedLength` (`src/core/object.zig:4095`)

- **签名**：`pub fn typedArrayFixedLength(self: *const Object) ?u32`。
- **作用**：查询 payload 的 fixed_length 字段。
- **实现**：typedArrayPayloadConst() 成功则返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：只读取存储字段，不执行构造、有效范围检查或状态变更。

### `Object.typedArrayPayloadFast` (`src/core/object.zig:4105`)

- **签名**：`pub fn typedArrayPayloadFast(self: *const Object) ?*const TypedArrayPayload`。
- **作用**：一次查询取得只读 TypedArrayPayload 借用。
- **实现**：直接返回 typedArrayPayloadConst()。
- **所有权 / 错误 / 调用**：不验证访问下标、detached 或越界，不创建 payload 或 root；供调用者自行读取缓存字段。

### `Object.collectionPayloadBorrowed` (`src/core/object.zig:4111`)

- **签名**：`pub fn collectionPayloadBorrowed(self: *const Object) ?*const CollectionPayload`。
- **作用**：借用只读 collection payload。
- **实现**：直接返回 collectionPayloadConst()。
- **所有权 / 错误 / 调用**：不持有 cursor、不创建 payload，也不延长对象存活；供检查器等读取条目和计数。

### `Object.typedArrayKindSlot` (`src/core/object.zig:4115`)

- **签名**：`pub fn typedArrayKindSlot(self: *Object) *u8`。
- **作用**：借用 view 或 native function 的 typed-array kind 槽。
- **实现**：优先返回 typedArrayPayload 的字段；否则断言不是 bytecode function，再尝试 functionPayload.native.typed_array_kind；都缺失则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload，直接写入不会自动刷新 view 缓存。支持 native constructor 元数据，不只支持 typed-array 实例。

### `Object.typedArrayKind` (`src/core/object.zig:4123`)

- **签名**：`pub fn typedArrayKind(self: *const Object) u8`。
- **作用**：查询 view 或 native function 的 typed-array kind。
- **实现**：优先读取 typedArrayPayload；bytecode function 返回 0；否则读取 functionPayload.native.typed_array_kind，缺失也返回 0。
- **所有权 / 错误 / 调用**：不验证字段含义或访问合法性，不分配。

### `Object.regexpSource` (`src/core/object.zig:4130`)

- **签名**：`pub fn regexpSource(self: *const Object) ?JSValue`。
- **作用**：查询 RegExp payload 的 source 值。
- **实现**：无 payload 或 source 指针为空时返回 null，否则调用 source.value()。
- **所有权 / 错误 / 调用**：不读取名为 source 的普通属性，也不做正则源文本转义；返回已有字符串表示的值。

### `Object.setRegexpSource` (`src/core/object.zig:4141`)

- **签名**：`pub fn setRegexpSource(self: *Object, rt: *JSRuntime, source_value: JSValue) !void`。
- **作用**：安装 RegExp source 字符串体并记录 GC 子边。
- **实现**：先调用 source_value.asStringBody，无字符串体则 TypeError；再检查 RegExp payload，缺失同样 TypeError；写 source 并 generationalBarrierValue。
- **所有权 / 错误 / 调用**：asStringBody 可物化 rope，且也接受 symbol 的字符串体，因此合法字符串参数由内部构造调用方保证；这里不执行 ToString 或编译正则。没有 RC retain/release。

### `Object.regexpLastIndexSlot` (`src/core/object.zig:4153`)

- **签名**：`pub inline fn regexpLastIndexSlot(self: *Object) *JSValue`。
- **作用**：借用固定位置的 lastIndex 数据槽。
- **实现**：断言 regexp class、至少一个属性、首 atom 为 lastIndex，且未删除、data、不可枚举及不可配置；返回首 property entry 的 data 字段地址。
- **所有权 / 错误 / 调用**：不要求 writable=true，裸写不会检查描述符或执行屏障；调用方负责写入语义与存活协议。

### `Object.regexpLastIndex` (`src/core/object.zig:4163`)

- **签名**：`pub inline fn regexpLastIndex(self: *const Object) ?JSValue`。
- **作用**：查询首属性中的 RegExp lastIndex 值。
- **实现**：class 错、无属性或首 atom 非 lastIndex 返回 null；否则 asDataAt(0)，删除或非 data 也返回 null。
- **所有权 / 错误 / 调用**：不沿原型链、不调用 getter，也不把值转换成整数；不验证 enumerable/configurable。

### `Object.regexpLastIndexWritable` (`src/core/object.zig:4169`)

- **签名**：`pub inline fn regexpLastIndexWritable(self: *const Object) bool`。
- **作用**：查询有效 lastIndex 数据属性是否可写。
- **实现**：regexpLastIndex 返回 null 则 false，否则读取首属性 writable。
- **所有权 / 错误 / 调用**：不尝试赋值或改变描述符；已有数据值为 JS null/undefined 并不等于 optional null。

### `Object.initializeRegExpLastIndex` (`src/core/object.zig:4178`)

- **签名**：`pub fn initializeRegExpLastIndex(self: *Object, rt: *JSRuntime) !void`。
- **作用**：为新 RegExp 安装首个 lastIndex 数据属性。
- **实现**：断言 regexp class 且 prop_count 为零，appendPreparedPropertyEntry(lastIndex, data(true,false,false), int32(0))，然后断言槽值为 0。
- **所有权 / 错误 / 调用**：追加可能失败并传播；属性可写、不可枚举、不可配置。无需每个实例独占 shape，实际 shape 转换由追加路径管理。

### `Object.regexpCompiledBytecode` (`src/core/object.zig:4190`)

- **签名**：`pub fn regexpCompiledBytecode(self: *const Object) []const u8`。
- **作用**：借用 RegExp 编译字节码的窄字符串数据。
- **实现**：无 payload 或 compiled_bytecode 则空 slice；否则 resolveData，latin1 返回 bytes，utf16 unreachable。
- **所有权 / 错误 / 调用**：不执行编译或验证字节码格式；借用依赖字符串存活，存储合同要求窄字符串。

### `Object.clearRegexpCompiledBytecode` (`src/core/object.zig:4201`)

- **签名**：`pub fn clearRegexpCompiledBytecode(self: *Object, _: *JSRuntime) void`。
- **作用**：清空 RegExp 编译字节码强边。
- **实现**：有 payload 则 compiled_bytecode=null；否则断言 regexp kind 后 unreachable。
- **所有权 / 错误 / 调用**：rt 未使用，不显式释放字符串或改变 source/lastIndex。

### `Object.setRegexpCompiledBytecode` (`src/core/object.zig:4210`)

- **签名**：`pub fn setRegexpCompiledBytecode(self: *Object, rt: *JSRuntime, bytecode: []const u8) !void`。
- **作用**：把字节 slice 复制为 GC 字符串并安装为编译字节码。
- **实现**：要求 RegExp payload；空 slice 委托 clear，否则 try String.createLatin1 后写 compiled_bytecode，再执行值屏障。
- **所有权 / 错误 / 调用**：字符串创建失败前不替换旧指针；不接管输入 slice 的释放责任，不验证正则字节码格式。

### `Object.setRegexpCompiledBytecodeString` (`src/core/object.zig:4233`)

- **签名**：`pub fn setRegexpCompiledBytecodeString(self: *Object, rt: *JSRuntime, bytecode: *string.String) !void`。
- **作用**：共享已有窄字符串作为 RegExp 编译字节码。
- **实现**：wide 或长度零返回 TypeError；有 payload 时直接写字符串指针并执行值屏障，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：没有源码注释所说的 RC retain；通过 GC 强边共享，不复制字节、不验证字节码格式。

### `Object.boundTargetSlot` (`src/core/object.zig:4244`)

- **签名**：`pub fn boundTargetSlot(self: *Object) *?JSValue`。
- **作用**：借用 boundFunction payload 的 target 可变槽。
- **实现**：有 payload 返回字段地址；否则断言相应 class 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接赋值不自动执行屏障、容量管理或 callable/handler 语义校验。

### `Object.boundTarget` (`src/core/object.zig:4250`)

- **签名**：`pub fn boundTarget(self: *const Object) ?JSValue`。
- **作用**：查询 boundFunction payload 的 target。
- **实现**：有对应 const payload 返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：不执行调用或 Proxy trap，不建立额外根，也不校验目标可调用性。

### `Object.boundThisSlot` (`src/core/object.zig:4255`)

- **签名**：`pub fn boundThisSlot(self: *Object) *?JSValue`。
- **作用**：借用 boundFunction payload 的 this_value 可变槽。
- **实现**：有 payload 返回字段地址；否则断言相应 class 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接赋值不自动执行屏障、容量管理或 callable/handler 语义校验。

### `Object.boundThis` (`src/core/object.zig:4261`)

- **签名**：`pub fn boundThis(self: *const Object) ?JSValue`。
- **作用**：查询 boundFunction payload 的 this_value。
- **实现**：有对应 const payload 返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：不执行调用或 Proxy trap，不建立额外根，也不校验目标可调用性。

### `Object.boundArgsSlot` (`src/core/object.zig:4266`)

- **签名**：`pub fn boundArgsSlot(self: *Object) *[]JSValue`。
- **作用**：借用 boundFunction payload 的 args 可变槽。
- **实现**：有 payload 返回字段地址；否则断言相应 class 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接赋值不自动执行屏障、容量管理或 callable/handler 语义校验。

### `Object.boundArgs` (`src/core/object.zig:4272`)

- **签名**：`pub fn boundArgs(self: *const Object) []JSValue`。
- **作用**：查询 boundFunction payload 的 args。
- **实现**：有对应 const payload 返回字段，否则返回 &.{}。
- **所有权 / 错误 / 调用**：不执行调用或 Proxy trap，不建立额外根；boundArgs 返回可变元素 slice，即使 self 为 const。

### `Object.ensureProxyPayload` (`src/core/object.zig:4277`)

- **签名**：`pub fn ensureProxyPayload(self: *Object, rt: *JSRuntime) !void`。
- **作用**：按需为 Proxy 安装 GC 管理的 payload。
- **实现**：断言 isProxy；已有 proxy payload 则返回，否则 createPayloadCell(ProxyPayload)，安装 arm/kind 后 rememberOwnerForBulkWrite。
- **所有权 / 错误 / 调用**：分配失败前不安装；不设置 target/handler 或判断撤销状态，也不替其他已有资源 payload 执行析构。

### `Object.proxyTargetSlot` (`src/core/object.zig:4286`)

- **签名**：`pub fn proxyTargetSlot(self: *Object) *?JSValue`。
- **作用**：借用 proxy payload 的 target 可变槽。
- **实现**：有 payload 返回字段地址；否则断言相应 class 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接赋值不自动执行屏障、容量管理或 callable/handler 语义校验。

### `Object.proxyTarget` (`src/core/object.zig:4292`)

- **签名**：`pub fn proxyTarget(self: *const Object) ?JSValue`。
- **作用**：查询 proxy payload 的 target。
- **实现**：有对应 const payload 返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：不执行调用或 Proxy trap，不建立额外根，也不校验目标可调用性。

### `Object.proxyHandlerSlot` (`src/core/object.zig:4297`)

- **签名**：`pub fn proxyHandlerSlot(self: *Object) *?JSValue`。
- **作用**：借用 proxy payload 的 handler 可变槽。
- **实现**：有 payload 返回字段地址；否则断言相应 class 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接赋值不自动执行屏障、容量管理或 callable/handler 语义校验。

### `Object.proxyHandler` (`src/core/object.zig:4303`)

- **签名**：`pub fn proxyHandler(self: *const Object) ?JSValue`。
- **作用**：查询 proxy payload 的 handler。
- **实现**：有对应 const payload 返回字段，否则返回 null。
- **所有权 / 错误 / 调用**：不执行调用或 Proxy trap，不建立额外根，也不校验目标可调用性。

### `Object.allocateMappedArgumentsVarRefsAssumingEmpty` (`src/core/object.zig:4314`)

- **签名**：`pub fn allocateMappedArgumentsVarRefsAssumingEmpty(self: *Object, rt: *JSRuntime, count: usize) ![]?*var_ref_mod.VarRef`。
- **作用**：为 mapped arguments 分配并清空 VarRef 指针表。
- **实现**：断言 class 为 mapped_arguments、kind 为 none、count/capacity 为零；count 零返回空。创建按 JSValue 大小分配的 array_storage cell，安装 values/count/capacity/length，标记 indexed properties 并 remember owner，再取得逻辑 VarRef slice 并全部置 null。
- **所有权 / 错误 / 调用**：count 转为 u32 使用 intCast，调用方须保证可表示。只初始化逻辑指针项，不是整个 JSValue backing；返回可变借用，后续写入 VarRef 边由调用方维护屏障。

### `Object.unmappedArgumentsDenseValues` (`src/core/object.zig:4344`)

- **签名**：`pub fn unmappedArgumentsDenseValues(self: *const Object) []const JSValue`。
- **作用**：借用未映射 arguments 的当前 dense 元素。
- **实现**：class 不是 arguments、fast_array 为 false 或 count 为零则空；断言 capacity>=count 后返回 values[0..count]。
- **所有权 / 错误 / 调用**：只返回存储元素，不执行可观察的 Get；不按 length 填补缺项，也不验证原型属性。

### `Object.fullyBoundMappedArgumentsVarRefs` (`src/core/object.zig:4360`)

- **签名**：`pub fn fullyBoundMappedArgumentsVarRefs(self: *const Object) ?[]const ?*var_ref_mod.VarRef`。
- **作用**：取得所有位置仍有绑定的 mapped arguments 指针表。
- **实现**：hasExoticMethods 或 proxyTarget 非空返回 null；取得 argumentsVarRefs，空则 null；任一 cell 为 null 也返回 null，否则返回 refs。
- **所有权 / 错误 / 调用**：非 mapped class 通过 argumentsVarRefs 的空结果拒绝。检查绑定存在，不读取变量值；失败由上层回退到可观察属性访问。

### `Object.argumentsVarRefs` (`src/core/object.zig:4370`)

- **签名**：`pub fn argumentsVarRefs(self: *const Object) []const ?*var_ref_mod.VarRef`。
- **作用**：借用 mapped arguments 的逻辑 VarRef 指针表。
- **实现**：非 mapped_arguments 或 count 零返回空；断言 capacity>=count，把 capacity 个 JSValue 的 backing 字节重解释成 ?*VarRef slice，再截取前 count 项。
- **所有权 / 错误 / 调用**：返回只读逻辑项；不分配、不验证每项是否绑定，也不更新屏障或引用状态。backing 的物理大小仍按 JSValue 容量计算。

### `Object.argumentsVarRefsMut` (`src/core/object.zig:4378`)

- **签名**：`pub fn argumentsVarRefsMut(self: *Object) []?*var_ref_mod.VarRef`。
- **作用**：借用 mapped arguments 的逻辑 VarRef 指针表。
- **实现**：非 mapped_arguments 或 count 零返回空；断言 capacity>=count，把 capacity 个 JSValue 的 backing 字节重解释成 ?*VarRef slice，再截取前 count 项。
- **所有权 / 错误 / 调用**：返回可变逻辑项；不分配、不验证每项是否绑定，也不更新屏障或引用状态。backing 的物理大小仍按 JSValue 容量计算。

### `Object.objectDataSlot` (`src/core/object.zig:4386`)

- **签名**：`pub fn objectDataSlot(self: *Object) *?JSValue`。
- **作用**：借用 object_data payload 的 data 槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload，直接写槽须由调用方维护 GC 屏障和语义。

### `Object.objectData` (`src/core/object.zig:4392`)

- **签名**：`pub fn objectData(self: *const Object) ?JSValue`。
- **作用**：查询 object_data payload 的可选值。
- **实现**：有 payload 返回 data，否则 null。
- **所有权 / 错误 / 调用**：不创建 payload，不进行 ToPrimitive 或包装类型校验。

### `Object.setWeakRefTarget` (`src/core/object.zig:4397`)

- **签名**：`pub fn setWeakRefTarget(self: *Object, rt: *JSRuntime, target: JSValue) !void`。
- **作用**：安装 WeakRef 的弱 target identity。
- **实现**：断言 weak_ref class；仅 target 放入 rootValues 帧，取得 identity 并登记 holder。取得 payload 后保存旧 identity，retain 新非空 identity、替换字段，release 旧 identity，最后 prune 空 holder。
- **所有权 / 错误 / 调用**：不把 target 变成强边，也不在这里执行 CanBeHeldWeakly 校验。retain/releaseWeakIdentity 对 object identity 无操作，仅 symbol atom 做弱引用计数。两个 fallible 步骤（identity 解析与 holder 登记）都排在任何 payload 写之前，因此失败时没有需要回滚的状态；写入 payload 之后原先那次重复的 registerBorrowedReferenceHolder 已删除（登记本身幂等）。self 的存活由调用方负责。

### `Object.weakRefDeref` (`src/core/object.zig:4421`)

- **签名**：`pub fn weakRefDeref(self: *const Object, rt: *JSRuntime) JSValue`。
- **作用**：解析 WeakRef identity，返回仍存活的目标。
- **实现**：断言 weak_ref class；无 payload/identity 则 undefined。奇数 identity 解出 atom，检查范围、symbol kind 和 live symbol 值；偶数 identity 用 liveObjectFromWeakIdentity。成功路径调用 keepAliveWeakRefTarget 后返回值。
- **所有权 / 错误 / 调用**：不因弱 identity 延长已死亡目标寿命。keepAlive helper 在扩容 OOM 时静默返回，因此本函数无 error 返回不能证明 keep-alive 表追加总能成功；不应照搬过时的 RC no-op 注释。

### `Object.arrayElementStorageMode` (`src/core/object.zig:4444`)

- **签名**：`pub fn arrayElementStorageMode(self: *const Object) ArrayStorageMode`。
- **作用**：按 fast_array 语义位报告 dense 或 sparse。
- **实现**：fast_array 为 true 返回 dense，否则 sparse。
- **所有权 / 错误 / 调用**：不检查 class、是否有 backing cell 或是否完全无尾洞。

### `Object.denseArmNamesStorageCell` (`src/core/object.zig:4460`)

- **签名**：`pub inline fn denseArmNamesStorageCell(self: *const Object) bool`。
- **作用**：判断 dense union arm 当前是否命名 GC storage cell。
- **实现**：array/mapped_arguments 以 capacity!=0 判断；arguments 还要求 payload kind==none；其他 class 返回 false。
- **所有权 / 错误 / 调用**：不依赖 fast_array：语义模式变化不能让 GC 漏掉仍挂接的 cell。仅对合法类读取对应 arm，不检查元素内容。

### `Object.arrayElements` (`src/core/object.zig:4468`)

- **签名**：`pub fn arrayElements(self: *const Object) []JSValue`。
- **作用**：借用当前有效 dense JSValue 元素 slice。
- **实现**：非 fast_array 或 count 零返回空；断言 capacity>=count 且 length>=count，返回 values[0..count]。
- **所有权 / 错误 / 调用**：不检查 class，不包含尾部空洞或容量余量；返回元素可变，即使 arrayElements 的 self 为 const。调用方维护写屏障及存活。

### `Object.arrayElementsMut` (`src/core/object.zig:4475`)

- **签名**：`fn arrayElementsMut(self: *Object) []JSValue`。
- **作用**：借用当前有效 dense JSValue 元素 slice。
- **实现**：非 fast_array 或 count 零返回空；断言 capacity>=count 且 length>=count，返回 values[0..count]。
- **所有权 / 错误 / 调用**：不检查 class，不包含尾部空洞或容量余量；返回元素可变，即使 arrayElements 的 self 为 const。调用方维护写屏障及存活。

### `Object.createArrayStorageCell` (`src/core/object.zig:4493`)

- **签名**：`pub fn createArrayStorageCell(rt: *JSRuntime, capacity: usize) ![*]JSValue`。
- **作用**：分配并发布 array_storage GC cell，返回 JSValue backing 指针。
- **实现**：断言 capacity 非零，checked mul/add 计算元素字节及 metadata 前缀，溢出 OutOfMemory；先 requestGCForAllocation(payload_bytes)，再 createStorageCellPublished(array_storage_kind_tag,total)，转换返回 body。
- **所有权 / 错误 / 调用**：元素未初始化；调用方须在暴露有效 count 前写好内容，发布后安装到 owner 前须遵守无额外收集窗口的协议。mapped arguments 也使用此物理布局，但按 VarRef 指针解释。

### `Object.createArrayStorageSlice` (`src/core/object.zig:4511`)

- **签名**：`pub fn createArrayStorageSlice(rt: *JSRuntime, capacity: usize) ![]JSValue`。
- **作用**：返回新 array_storage cell 的 capacity 长度 slice。
- **实现**：委托 createArrayStorageCell 后切 base[0..capacity]。
- **所有权 / 错误 / 调用**：沿用非零容量和未初始化内容合同；不是 runtime allocator 普通 slice，不应手动 memory.free。

### `Object.arrayStorageCellHeader` (`src/core/object.zig:4519`)

- **签名**：`pub inline fn arrayStorageCellHeader(values: [*]JSValue) *gc.Header`。
- **作用**：把 storage body 地址解释成 GC header。
- **实现**：对 values 执行 alignCast/ptrCast。
- **所有权 / 错误 / 调用**：不查注册表或验证 cell kind；只适用于实际已发布 cell，不能用于空 arm 的 sentinel。

### `Object.arrayElementsCapacity` (`src/core/object.zig:4523`)

- **签名**：`pub fn arrayElementsCapacity(self: *const Object) usize`。
- **作用**：读取 array arm 的物理 capacity。
- **实现**：直接将 arrayArm.capacity 转为 usize。
- **所有权 / 错误 / 调用**：不检查 fast_array 或语义 class；调用方须保证 arm 可按 dense storage 解释。

### `Object.isFastArray` (`src/core/object.zig:4527`)

- **签名**：`pub fn isFastArray(self: *const Object) bool`。
- **作用**：判断对象是否是启用 fast_array 的 Array。
- **实现**：同时检查 isArray() 和 flags.fast_array。
- **所有权 / 错误 / 调用**：不保证 count==length，也不检查 length writable 或原型索引属性。

### `Object.isFastArrayIndexInBounds` (`src/core/object.zig:4531`)

- **签名**：`pub fn isFastArrayIndexInBounds(self: *const Object, index: u32) bool`。
- **作用**：判断下标是否位于 fast_array 的有效 dense extent 内。
- **实现**：检查 fast_array 且 index<count。
- **所有权 / 错误 / 调用**：没有 isArray class 检查，不能据此解释 mapped arguments 指针表为 JSValue；调用方须确保存储类型。

### `Object.fastArrayElementAt` (`src/core/object.zig:4535`)

- **签名**：`pub fn fastArrayElementAt(self: *const Object, index: u32) JSValue`。
- **作用**：直接读取已知有效 dense 下标值。
- **实现**：断言 isFastArrayIndexInBounds 后读 values[index]。
- **所有权 / 错误 / 调用**：不执行 Get/原型查询或建立根，不检查描述符；调用方保证 JSValue dense 存储。

### `Object.fastArrayElementDup` (`src/core/object.zig:4540`)

- **签名**：`pub fn fastArrayElementDup(self: *const Object, index: u32) ?JSValue`。
- **作用**：尝试读取 dense extent 内的值。
- **实现**：isFastArrayIndexInBounds 为 false 返回 null，否则按值返回 values[index]。
- **所有权 / 错误 / 调用**：Dup 名称不表示当前实现做 RC retain，也不建立 GC 根；不执行一般属性访问。

### `Object.mappedArgumentsElementDup` (`src/core/object.zig:4561`)

- **签名**：`pub noinline fn mappedArgumentsElementDup(self: *const Object, index: u32) ?JSValue`。
- **作用**：读取仍绑定的 mapped arguments 下标值。
- **实现**：noinline 包装，直接委托 mappedArgumentsIntElementDup。
- **所有权 / 错误 / 调用**：不处理已解除绑定的索引；null 由上层转入普通 Get，不执行 RC dup。

### `Object.mappedArgumentsIntElementDup` (`src/core/object.zig:4568`)

- **签名**：`pub inline fn mappedArgumentsIntElementDup(self: *const Object, index: u32) ?JSValue`。
- **作用**：从 mapped arguments 的 VarRef 读取当前槽值。
- **实现**：非 mapped_arguments、index 超过 refs 长度或 cell 为 null 均返回 null；否则返回 cell.pvalue.*。
- **所有权 / 错误 / 调用**：不执行 getter、原型查询或独立 TDZ 检查；不复制 VarRef，也不增加值引用计数。

### `Object.setFastArrayElementDup` (`src/core/object.zig:4576`)

- **签名**：`pub fn setFastArrayElementDup(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool`。
- **作用**：尝试替换 dense extent 内的元素并执行值屏障。
- **实现**：越过 isFastArrayIndexInBounds 返回 false；否则直接写槽，再 generationalBarrier(self,new_value)，返回 true。
- **所有权 / 错误 / 调用**：不改变 count/length、不检查 writable/prototype/class 语义，也不在这里验证是否处于 active bytecode。当前没有 RC retain/release；false 不安装输入值。

### `Object.setFastArrayElementOwned` (`src/core/object.zig:4587`)

- **签名**：`pub fn setFastArrayElementOwned(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool`。
- **作用**：尝试替换 dense extent 内的元素并执行值屏障。
- **实现**：越过 isFastArrayIndexInBounds 返回 false；否则通过 replaceOwnedValue 写槽，其当前实现仅赋值，再 generationalBarrier(self,new_value)，返回 true。
- **所有权 / 错误 / 调用**：不改变 count/length、不检查 writable/prototype/class 语义，也不在这里验证是否处于 active bytecode。当前没有 RC retain/release；false 不安装输入值。

### `Object.setFastArrayElementOwnedDuringActiveBytecode` (`src/core/object.zig:4595`)

- **签名**：`pub fn setFastArrayElementOwnedDuringActiveBytecode(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool`。
- **作用**：尝试替换 dense extent 内的元素并执行值屏障。
- **实现**：越过 isFastArrayIndexInBounds 返回 false；否则直接写槽，再 generationalBarrier(self,new_value)，返回 true。
- **所有权 / 错误 / 调用**：不改变 count/length、不检查 writable/prototype/class 语义，也不在这里验证是否处于 active bytecode。当前没有 RC retain/release；false 不安装输入值。

### `Object.adoptDenseArrayElementsAssumingEmpty` (`src/core/object.zig:4614`)

- **签名**：`pub fn adoptDenseArrayElementsAssumingEmpty(self: *Object, rt: *JSRuntime, elements: []JSValue) void`。
- **作用**：将已初始化的 GC 元素存储安装到空 Array。
- **实现**：断言 Array 且 count/capacity 为零；安装 elements.ptr，count/capacity/length 均设为 slice 长度，fast_array=true，remember owner。
- **所有权 / 错误 / 调用**：不分配、不复制或验证元素初始化；非空 buffer 必须是合适的 array_storage cell，长度必须可转为 u32。不在此设置 indexed-properties 摘要位或校验 length writable。

### `Object.adoptDenseUnmappedArgumentsElementsAssumingEmpty` (`src/core/object.zig:4631`)

- **签名**：`pub fn adoptDenseUnmappedArgumentsElementsAssumingEmpty(self: *Object, rt: *JSRuntime, elements: []JSValue) void`。
- **作用**：将已初始化的 GC 元素存储安装到空 unmapped arguments。
- **实现**：断言 arguments、支持 plain named storage、kind none、count/capacity 零；非空时写 values；三个长度字段赋为 slice 长度并置 fast_array。非空则 markIndexedProperties，随后始终 remember owner。
- **所有权 / 错误 / 调用**：不改变 shape 上的普通 length 属性；不分配或复制元素，非空 backing 必须符合 array_storage cell 合同。

### `Object.takeLastFullyDenseFastArrayElement` (`src/core/object.zig:4653`)

- **签名**：`pub fn takeLastFullyDenseFastArrayElement(self: *Object) ?JSValue`。
- **作用**：从完全 dense 的非空 Array 取出尾元素。
- **实现**：非 Array、非 fast、count 零或 count!=length 返回 null；否则 count 和 length 各减一，返回旧尾值。
- **所有权 / 错误 / 调用**：不缩 capacity、不清尾槽、不检查 length writable 或描述符。尾值后续存活由调用方负责；null 表示无法采用此路径。

### `Object.freeArrayElementBufferAfterMove` (`src/core/object.zig:4664`)

- **签名**：`fn freeArrayElementBufferAfterMove(self: *Object) void`。
- **作用**：解除 dense backing 的 owner 追踪边并退出 fast 模式。
- **实现**：断言非 fast 或 count 为零，置 capacity=0、fast_array=false。
- **所有权 / 错误 / 调用**：不立即释放 cell，不清 values/count/length；旧 cell 在失去可达边后由 GC 回收，调用方须已完成数据迁移。

### `Object.ensureArrayBufferCapacity` (`src/core/object.zig:4670`)

- **签名**：`fn ensureArrayBufferCapacity(self: *Object, rt: *JSRuntime, needed_len: usize) !void`。
- **作用**：按需扩充 dense backing 容量。
- **实现**：needed<=old_capacity 则返回；从空容量精确取 needed，否则先加一半，至少增长一项，再反复加 max(capacity/2,1) 直到足够。超过 u32 返回 OutOfMemory；创建新 cell，仅 fast 且 count 非零时复制有效项，安装 pointer/capacity 并屏障新 cell。
- **所有权 / 错误 / 调用**：不是一次 max(needed,old*3/2)，大跨度增长可能经过多轮；增长算术本身非 checked。失败前不替换 backing；不改 count/length，余量未初始化，旧 cell 交 GC。

### `Object.appendInitializedFastArrayValue` (`src/core/object.zig:4708`)

- **签名**：`fn appendInitializedFastArrayValue(self: *Object, rt: *JSRuntime, new_value: JSValue) !void`。
- **作用**：追加已知值到 dense extent。
- **实现**：保存 count 为 index，确保 index+1 容量，先写元素再增加 count、置 fast_array，最后屏障该值。
- **所有权 / 错误 / 调用**：不增加逻辑 length 或检查 class；调用方在容量分配期间保护 new_value/self，并维护语义长度和属性条件。

### `Object.appendUninitializedFastArraySlot` (`src/core/object.zig:4717`)

- **签名**：`pub fn appendUninitializedFastArraySlot(self: *Object, rt: *JSRuntime) !*JSValue`。
- **作用**：扩展 dense extent 并返回尚待填充的槽。
- **实现**：确保 count+1 容量，再递增 count、置 fast_array、remember owner，返回旧 count 位置。
- **所有权 / 错误 / 调用**：函数返回时 count 已包含未初始化槽，调用方必须立即初始化，不能在中间触发可观察该槽的 GC/遍历；不增加逻辑 length。

### `Object.fastArrayEnsureCapacity` (`src/core/object.zig:4729`)

- **签名**：`pub fn fastArrayEnsureCapacity(self: *Object, rt: *JSRuntime, needed: u32) !void`。
- **作用**：确保 array arm 至少容纳 needed 个元素。
- **实现**：将 needed 转为 usize 后委托 ensureArrayBufferCapacity。
- **所有权 / 错误 / 调用**：不改变 count/length，不自动初始化余量或设置 fast_array。

### `Object.fastArrayCount` (`src/core/object.zig:4733`)

- **签名**：`pub fn fastArrayCount(self: *const Object) u32`。
- **作用**：读取 fast Array 的有效 dense 个数。
- **实现**：isFastArray 为 true 返回 count，否则 0。
- **所有权 / 错误 / 调用**：不返回 JS length，也不适用于 mapped/unmapped arguments 的计数查询。

### `Object.fastArrayCapacity` (`src/core/object.zig:4737`)

- **签名**：`pub fn fastArrayCapacity(self: *const Object) u32`。
- **作用**：直接读取 array arm 容量。
- **实现**：返回 arrayArm.capacity。
- **所有权 / 错误 / 调用**：不检查 isFastArray/class；调用方须保证存储布局有效。

### `Object.fastArrayValues` (`src/core/object.zig:4741`)

- **签名**：`pub fn fastArrayValues(self: *const Object) []JSValue`。
- **作用**：借用有效 dense JSValue 元素。
- **实现**：直接委托 arrayElements。
- **所有权 / 错误 / 调用**：返回可变元素 slice，不分配、复制或触发一般 Get；修改需维护 owner 屏障。

### `Object.fastArrayValuesMut` (`src/core/object.zig:4745`)

- **签名**：`pub fn fastArrayValuesMut(self: *Object) []JSValue`。
- **作用**：借用有效 dense JSValue 元素。
- **实现**：直接委托 arrayElementsMut。
- **所有权 / 错误 / 调用**：返回可变元素 slice，不分配、复制或触发一般 Get；修改需维护 owner 屏障。

### `Object.setFastArrayCountAssumeCapacity` (`src/core/object.zig:4749`)

- **签名**：`pub fn setFastArrayCountAssumeCapacity(self: *Object, count: u32) void`。
- **作用**：直接设置 dense count 并启用 fast 模式。
- **实现**：断言 count<=capacity，写 count 和 fast_array=true。
- **所有权 / 错误 / 调用**：不初始化新增范围、不更新 length、不执行屏障；调用方负责元素和 count<=length 等不变量。

### `Object.fastArraySlotAssumeCapacity` (`src/core/object.zig:4755`)

- **签名**：`pub fn fastArraySlotAssumeCapacity(self: *Object, index: u32) *JSValue`。
- **作用**：借用 capacity 内的元素槽。
- **实现**：断言 index<capacity 后返回 values[index] 地址。
- **所有权 / 错误 / 调用**：可指向当前 count 之外的未初始化位置；不增加 count/length，也不在裸写时执行屏障。

### `Object.promiseResultSlot` (`src/core/object.zig:4761`)

- **签名**：`pub fn promiseResultSlot(self: *Object) *?JSValue`。
- **作用**：借用 Promise payload 的 result 可变槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接修改不自动执行屏障、分配/释放存储或触发 Promise 状态转换，调用方须维护相应协议。

### `Object.promiseResult` (`src/core/object.zig:4767`)

- **签名**：`pub fn promiseResult(self: *const Object) ?JSValue`。
- **作用**：查询 Promise payload 的 result。
- **实现**：promisePayloadConst() 成功则返回字段，否则 null。
- **所有权 / 错误 / 调用**：不推进 Promise 状态、执行回调或排 job。只读取存储字段，不创建 payload 或建立额外根。

### `Object.promiseReactionCallbackSlot` (`src/core/object.zig:4772`)

- **签名**：`pub fn promiseReactionCallbackSlot(self: *Object) *?JSValue`。
- **作用**：借用 Promise payload 的 reaction_callback 可变槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接修改不自动执行屏障、分配/释放存储或触发 Promise 状态转换，调用方须维护相应协议。

### `Object.promiseReactionCallback` (`src/core/object.zig:4778`)

- **签名**：`pub fn promiseReactionCallback(self: *const Object) ?JSValue`。
- **作用**：查询 Promise payload 的 reaction_callback。
- **实现**：promisePayloadConst() 成功则返回字段，否则 null。
- **所有权 / 错误 / 调用**：不推进 Promise 状态、执行回调或排 job。只读取存储字段，不创建 payload 或建立额外根。

### `Object.promiseReactionArgSlot` (`src/core/object.zig:4783`)

- **签名**：`pub fn promiseReactionArgSlot(self: *Object) *?JSValue`。
- **作用**：借用 Promise payload 的 reaction_arg 可变槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接修改不自动执行屏障、分配/释放存储或触发 Promise 状态转换，调用方须维护相应协议。

### `Object.promiseReactionArg` (`src/core/object.zig:4789`)

- **签名**：`pub fn promiseReactionArg(self: *const Object) ?JSValue`。
- **作用**：查询 Promise payload 的 reaction_arg。
- **实现**：promisePayloadConst() 成功则返回字段，否则 null。
- **所有权 / 错误 / 调用**：不推进 Promise 状态、执行回调或排 job。只读取存储字段，不创建 payload 或建立额外根。

### `Object.promiseReactionsSlot` (`src/core/object.zig:4794`)

- **签名**：`pub fn promiseReactionsSlot(self: *Object) *[]JSValue`。
- **作用**：借用 Promise payload 的 reactions 可变槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接修改不自动执行屏障、分配/释放存储或触发 Promise 状态转换，调用方须维护相应协议。

### `Object.promiseReactions` (`src/core/object.zig:4800`)

- **签名**：`pub fn promiseReactions(self: *const Object) []JSValue`。
- **作用**：查询 Promise payload 的 reactions。
- **实现**：promisePayloadConst() 成功则返回字段，否则 &.{}。
- **所有权 / 错误 / 调用**：不推进 Promise 状态、执行回调或排 job。返回可变元素 slice，虽然 self 为 const；不复制或建立根。

### `Object.promiseReactionsCapacitySlot` (`src/core/object.zig:4805`)

- **签名**：`pub fn promiseReactionsCapacitySlot(self: *Object) *usize`。
- **作用**：借用 Promise reactions_capacity 字段槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：修改字段不分配 reactions backing，须与实际分配容量和 slice 保持一致。

### `Object.promiseIsRejectedSlot` (`src/core/object.zig:4811`)

- **签名**：`pub fn promiseIsRejectedSlot(self: *Object) *bool`。
- **作用**：借用 Promise payload 的 is_rejected 可变槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接修改不自动执行屏障、分配/释放存储或触发 Promise 状态转换，调用方须维护相应协议。

### `Object.promiseIsRejected` (`src/core/object.zig:4817`)

- **签名**：`pub fn promiseIsRejected(self: *const Object) bool`。
- **作用**：查询 Promise payload 的 is_rejected。
- **实现**：promisePayloadConst() 成功则返回字段，否则 false。
- **所有权 / 错误 / 调用**：不推进 Promise 状态、执行回调或排 job。只读取存储字段，不创建 payload 或建立额外根。

### `Object.promiseAtomicsWaitAsyncSlot` (`src/core/object.zig:4822`)

- **签名**：`pub fn promiseAtomicsWaitAsyncSlot(self: *Object) *bool`。
- **作用**：借用 Promise payload 的 atomics_wait_async 可变槽。
- **实现**：promisePayload() 成功返回字段地址，否则断言 kind 为 promise 后 unreachable。
- **所有权 / 错误 / 调用**：不创建 payload；直接修改不自动执行屏障、分配/释放存储或触发 Promise 状态转换，调用方须维护相应协议。

### `Object.promiseAtomicsWaitAsync` (`src/core/object.zig:4828`)

- **签名**：`pub fn promiseAtomicsWaitAsync(self: *const Object) bool`。
- **作用**：查询 Promise payload 的 atomics_wait_async。
- **实现**：promisePayloadConst() 成功则返回字段，否则 false。
- **所有权 / 错误 / 调用**：不推进 Promise 状态、执行回调或排 job。只读取存储字段，不创建 payload 或建立额外根。

### `Object.initGeneratorExecutionWithStorage` (`src/core/object.zig:4836`)

- **签名**：`pub fn initGeneratorExecutionWithStorage(self: *Object, rt: *JSRuntime, stack_slots: usize, frame_slots: usize) !void`。
- **作用**：为已有 generator payload 安装带尾随 stack/frame 空间的执行记录。
- **实现**：要求 generator payload 且 execution==null；调用 createGeneratorExecutionStateWithStorage，成功后赋给 execution。
- **所有权 / 错误 / 调用**：分配或尺寸校验错误传播，失败时 execution 保持 null；helper 初始化记录与 slice 描述，不初始化所有尾随 JSValue。这里不设置 done/started，也不执行恢复。

### `Object.generatorLiveExecution` (`src/core/object.zig:4845`)

- **签名**：`fn generatorLiveExecution(self: *Object) *GeneratorExecutionState`。
- **作用**：取得必须存在的 generator 执行记录。
- **实现**：无 generator payload 则断言 kind 后 unreachable；execution 非空直接返回，否则断言 !done 后仍 unreachable。
- **所有权 / 错误 / 调用**：不是检查 done 后返回 optional 的安全查询：调用者须保证 execution 存在；不分配或延长存活。

### `Object.generatorPayloadPtr` (`src/core/object.zig:4859`)

- **签名**：`pub inline fn generatorPayloadPtr(self: *Object) *GeneratorPayload`。
- **作用**：直接借用已证明为 generator 的 payload。
- **实现**：断言 class 为 generator/async_generator，kind 为 generator，解包 arm 非空并转换指针。
- **所有权 / 错误 / 调用**：绕过一般 payload 分派；不验证 execution 存在或状态可恢复，不创建额外根。

### `Object.attachGeneratorOpenVarRefOwners` (`src/core/object.zig:4867`)

- **签名**：`pub fn attachGeneratorOpenVarRefOwners(self: *Object, rt: *JSRuntime) void`。
- **作用**：把暂停 frame 的 open VarRef 关联到 generator owner。
- **实现**：通过 generatorPayloadPtr 取得 execution，无记录返回；遍历 frame.open_var_refs，跳过 null，对其余 cell 调用 attachOpenOwner(rt,self.value())。
- **所有权 / 错误 / 调用**：attachOpenOwner 要求 cell 为 open，已关联时断言同一 owner，否则安装 cell 到 owner 的 GC 强边并屏障；不是保留借用 pvalue 的独立堆引用。

### `Object.generatorThisSlot` (`src/core/object.zig:4877`)

- **签名**：`pub fn generatorThisSlot(self: *Object) *JSValue`。
- **作用**：借用执行记录的 this_value 字段槽。
- **实现**：通过 generatorLiveExecution() 取得记录后返回字段地址。
- **所有权 / 错误 / 调用**：要求记录已存在；直接写槽不执行屏障、分配或校验状态，记录释放后借用失效。

### `Object.setGeneratorThis` (`src/core/object.zig:4881`)

- **签名**：`pub fn setGeneratorThis(self: *Object, rt: *JSRuntime, next_value: JSValue) void`。
- **作用**：设置执行记录的 this_value。
- **实现**：通过 generatorLiveExecution 或对应 Slot 取得字段，用 replaceOwnedValue 写入 next_value。
- **所有权 / 错误 / 调用**：replaceOwnedValue 当前仅赋值，没有 RC 操作或 owner 屏障；调用方承担该存储时点的 GC 保护协议。

### `Object.generatorThis` (`src/core/object.zig:4885`)

- **签名**：`pub fn generatorThis(self: *const Object) ?JSValue`。
- **作用**：查询执行记录的 this_value。
- **实现**：缺 payload 或 execution 返回 null，否则返回字段。
- **所有权 / 错误 / 调用**：只读存储字段，不分配、不执行恢复或建立额外根。

### `Object.generatorArgs` (`src/core/object.zig:4893`)

- **签名**：`pub fn generatorArgs(self: *const Object) []JSValue`。
- **作用**：查询执行记录的 suspended.storage.frame.args。
- **实现**：缺 payload 或 execution 返回 &.{}，否则返回字段。
- **所有权 / 错误 / 调用**：不分配或建立根；slice 返回的是已有存储的可变借用，标量返回字段值。不执行恢复或修改 PC。

### `Object.generatorCaptures` (`src/core/object.zig:4901`)

- **签名**：`pub fn generatorCaptures(self: *const Object) []*var_ref_mod.VarRef`。
- **作用**：查询执行记录的 suspended.storage.frame.var_refs。
- **实现**：缺 payload 或 execution 返回 &.{}，否则返回字段。
- **所有权 / 错误 / 调用**：不分配或建立根；slice 返回的是已有存储的可变借用，标量返回字段值。不执行恢复或修改 PC。

### `Object.generatorActualArgCountSlot` (`src/core/object.zig:4909`)

- **签名**：`pub fn generatorActualArgCountSlot(self: *Object) *u16`。
- **作用**：借用执行记录的 actual_arg_count 字段槽。
- **实现**：通过 generatorLiveExecution() 取得记录后返回字段地址。
- **所有权 / 错误 / 调用**：要求记录已存在；直接写槽不执行屏障、分配或校验状态，记录释放后借用失效。

### `Object.generatorActualArgCount` (`src/core/object.zig:4913`)

- **签名**：`pub fn generatorActualArgCount(self: *const Object) usize`。
- **作用**：查询执行记录的 actual_arg_count。
- **实现**：缺 payload 或 execution 返回 0，否则返回字段。
- **所有权 / 错误 / 调用**：只读存储字段，不分配、不执行恢复或建立额外根。

### `Object.generatorExecutionStateSlot` (`src/core/object.zig:4921`)

- **签名**：`pub fn generatorExecutionStateSlot(self: *Object) *SuspendedExecutionState`。
- **作用**：借用执行记录的 suspended 字段槽。
- **实现**：通过 generatorLiveExecution() 取得记录后返回字段地址。
- **所有权 / 错误 / 调用**：要求记录已存在；直接写槽不执行屏障、分配或校验状态，记录释放后借用失效。

### `Object.generatorExecutionState` (`src/core/object.zig:4925`)

- **签名**：`pub fn generatorExecutionState(self: *const Object) *const SuspendedExecutionState`。
- **作用**：借用 generator 的只读 suspended state。
- **实现**：有 payload 且 execution 存在则返回 suspended 地址；有 payload 但无 execution 返回全局 empty_suspended_execution_state；无 payload 断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：空记录与错误对象处理不同；借用在执行记录销毁后失效，不复制 state。

### `Object.generatorStackUsesCombinedStorage` (`src/core/object.zig:4934`)

- **签名**：`pub fn generatorStackUsesCombinedStorage(self: *Object) bool`。
- **作用**：判断当前 stack 是否引用执行记录尾随空间。
- **实现**：缺 payload 或 execution 返回 false，否则委托 execution.stackUsesCombinedStorage。
- **所有权 / 错误 / 调用**：helper 要求 combined stack 非空、当前 capacity 非零且指针相同；不是只检查创建时是否请求过 stack slots。

### `Object.generatorCombinedFrameStorage` (`src/core/object.zig:4940`)

- **签名**：`pub fn generatorCombinedFrameStorage(self: *Object) []JSValue`。
- **作用**：借用执行记录尾随 frame 存储区。
- **实现**：缺 payload 或 execution 返回空，否则返回 execution.combinedFrameStorage()。
- **所有权 / 错误 / 调用**：按创建时记录的 frame 槽数定位尾随区，不以当前 suspended frame 是否引用它为条件；内容可变，不分配或建立根。

### `Object.generatorFrameUsesCombinedStorage` (`src/core/object.zig:4946`)

- **签名**：`pub fn generatorFrameUsesCombinedStorage(self: *Object) bool`。
- **作用**：判断当前 frame 是否引用执行记录尾随空间。
- **实现**：缺 payload 或 execution 返回 false，否则委托 execution.frameUsesCombinedStorage。
- **所有权 / 错误 / 调用**：helper 要求 combined frame 非空、当前 storage 非空且指针相同；不检查所有 frame 子 slice 的范围。

### `Object.finalizeGeneratorExecutionCompletion` (`src/core/object.zig:4955`)

- **签名**：`pub fn finalizeGeneratorExecutionCompletion(self: *Object, rt: *JSRuntime) void`。
- **作用**：在运行别名解除后释放待完成的执行记录。
- **实现**：缺 payload/execution 或 completionPending 为 false 则返回；断言 !running_aliases，清 pending 位，再 destroyGeneratorExecutionState。
- **所有权 / 错误 / 调用**：必须由外层在 live Frame/Stack 完成清理后调用；销毁 helper 先将 payload.execution 置 null，再清理并释放记录。这里只处理已标 pending 的记录，不根据 done 独立判断。

### `Object.setGeneratorCurrentFunction` (`src/core/object.zig:4964`)

- **签名**：`pub fn setGeneratorCurrentFunction(self: *Object, rt: *JSRuntime, next_value: JSValue) void`。
- **作用**：设置执行记录的 current_function。
- **实现**：通过 generatorLiveExecution 或对应 Slot 取得字段，用 replaceOwnedValue 写入 next_value。
- **所有权 / 错误 / 调用**：replaceOwnedValue 当前仅赋值，没有 RC 操作或 owner 屏障；调用方承担该存储时点的 GC 保护协议。

### `Object.generatorCurrentFunction` (`src/core/object.zig:4968`)

- **签名**：`pub fn generatorCurrentFunction(self: *const Object) ?JSValue`。
- **作用**：查询 generator 保存的当前函数。
- **实现**：无 payload/执行记录或 current_function 为 undefined 则 null，否则按值返回。
- **所有权 / 错误 / 调用**：undefined 被映射为 optional null；不调用函数或 retain 值。

### `Object.generatorYieldStarIteratorSlot` (`src/core/object.zig:4977`)

- **签名**：`pub fn generatorYieldStarIteratorSlot(self: *Object) *JSValue`。
- **作用**：借用执行记录的 yield_star_iterator 字段槽。
- **实现**：通过 generatorLiveExecution() 取得记录后返回字段地址。
- **所有权 / 错误 / 调用**：要求记录已存在；直接写槽不执行屏障、分配或校验状态，记录释放后借用失效。

### `Object.setGeneratorYieldStarIterator` (`src/core/object.zig:4981`)

- **签名**：`pub fn setGeneratorYieldStarIterator(self: *Object, rt: *JSRuntime, next_value: JSValue) void`。
- **作用**：设置执行记录的 yield_star_iterator。
- **实现**：通过 generatorLiveExecution 或对应 Slot 取得字段，用 replaceOwnedValue 写入 next_value。
- **所有权 / 错误 / 调用**：replaceOwnedValue 当前仅赋值，没有 RC 操作或 owner 屏障；调用方承担该存储时点的 GC 保护协议。

### `Object.clearGeneratorYieldStarIterator` (`src/core/object.zig:4985`)

- **签名**：`pub fn clearGeneratorYieldStarIterator(self: *Object, rt: *JSRuntime) void`。
- **作用**：清空 generator 执行记录的 yield-star iterator。
- **实现**：借用对应槽后调用 destroyOwnedValue，其当前实现仅写 undefined。
- **所有权 / 错误 / 调用**：要求执行记录存在；不调用 iterator.return、不执行 RC release 或 GC 屏障。

### `Object.generatorYieldStarIterator` (`src/core/object.zig:4989`)

- **签名**：`pub fn generatorYieldStarIterator(self: *const Object) ?JSValue`。
- **作用**：查询 generator 的 yield-star iterator 值。
- **实现**：无 payload/执行记录或字段为 undefined 则 null，否则返回字段。
- **所有权 / 错误 / 调用**：不调用 next、检查 iterator 类型或 retain 值。

### `Object.generatorAsyncPromiseSlot` (`src/core/object.zig:4998`)

- **签名**：`pub fn generatorAsyncPromiseSlot(self: *Object) *?JSValue`。
- **作用**：借用 generator payload 的 async_promise 可变槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配；直接写入不执行屏障或完成相关状态转换，调用方维护字段间不变量。

### `Object.generatorAsyncPromise` (`src/core/object.zig:5004`)

- **签名**：`pub fn generatorAsyncPromise(self: *const Object) ?JSValue`。
- **作用**：查询 generator payload 的 async_promise。
- **实现**：有 payload 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不要求 execution 存在，不推进状态或执行相应动作。

### `Object.generatorPcSlot` (`src/core/object.zig:5009`)

- **签名**：`pub fn generatorPcSlot(self: *Object) *usize`。
- **作用**：借用执行记录的 suspended.pc 字段槽。
- **实现**：通过 generatorLiveExecution() 取得记录后返回字段地址。
- **所有权 / 错误 / 调用**：要求记录已存在；直接写槽不执行屏障、分配或校验状态，记录释放后借用失效。

### `Object.generatorPc` (`src/core/object.zig:5013`)

- **签名**：`pub fn generatorPc(self: *const Object) usize`。
- **作用**：查询执行记录的 suspended.pc。
- **实现**：缺 payload 或 execution 返回 0，否则返回字段。
- **所有权 / 错误 / 调用**：只读存储字段，不分配、不执行恢复或建立额外根。

### `Object.generatorResumeCompletionTypeSlot` (`src/core/object.zig:5021`)

- **签名**：`pub fn generatorResumeCompletionTypeSlot(self: *Object) *i32`。
- **作用**：借用 generator payload 的 resume_completion_type 可变槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配；直接写入不执行屏障或完成相关状态转换，调用方维护字段间不变量。

### `Object.generatorResumeCompletionType` (`src/core/object.zig:5027`)

- **签名**：`pub fn generatorResumeCompletionType(self: *const Object) i32`。
- **作用**：查询 generator payload 的 resume_completion_type。
- **实现**：有 payload 返回字段，否则 0。
- **所有权 / 错误 / 调用**：不要求 execution 存在，不推进状态或执行相应动作。

### `Object.generatorDoneSlot` (`src/core/object.zig:5032`)

- **签名**：`pub fn generatorDoneSlot(self: *Object) *bool`。
- **作用**：借用 generator payload 的 done 可变槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配；直接写入不执行屏障或完成相关状态转换，调用方维护字段间不变量。

### `Object.completeGeneratorExecution` (`src/core/object.zig:5055`)

- **签名**：`pub noinline fn completeGeneratorExecution(self: *Object, rt: *JSRuntime) void`。
- **作用**：发布 generator 完成状态并立即或延后销毁执行记录。
- **实现**：要求 payload；置 done=true、just_yielded=false、resume_completion_type=0、yield_star_suspended=false。有 execution 时若 running_aliases 则设 completionPending，否则直接 destroyGeneratorExecutionState。
- **所有权 / 错误 / 调用**：运行中的 Frame/Stack 仍可能借用执行记录，必须等外层 finalize 才释放。不会在这里清 executing/started/suspend_kind、async_promise 或 async_queue，也不排 Promise job。

### `Object.generatorDone` (`src/core/object.zig:5038`)

- **签名**：`pub fn generatorDone(self: *const Object) bool`。
- **作用**：查询 generator payload 的 done。
- **实现**：有 payload 返回字段，否则 false。
- **所有权 / 错误 / 调用**：不要求 execution 存在，不推进状态或执行相应动作。

### `Object.generatorExecutingSlot` (`src/core/object.zig:5078`)

- **签名**：`pub fn generatorExecutingSlot(self: *Object) *bool`。
- **作用**：借用 generator 或 iterator 的 executing 标志槽。
- **实现**：优先 generator payload，其次 iterator payload；都无则断言 generator kind 后 unreachable。
- **所有权 / 错误 / 调用**：不只服务 generator class；直接写槽不执行重入检查或状态转换。

### `Object.generatorExecuting` (`src/core/object.zig:5085`)

- **签名**：`pub fn generatorExecuting(self: *const Object) bool`。
- **作用**：查询 generator 或 iterator 的 executing 标志。
- **实现**：优先读取 generator payload，再读 iterator payload；均不存在返回 false。
- **所有权 / 错误 / 调用**：只读标志，不据此证明执行记录存在或当前线程持有执行权。

### `Object.generatorStartedSlot` (`src/core/object.zig:5091`)

- **签名**：`pub fn generatorStartedSlot(self: *Object) *bool`。
- **作用**：借用 generator payload 的 started 可变槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配；直接写入不执行屏障或完成相关状态转换，调用方维护字段间不变量。

### `Object.generatorStarted` (`src/core/object.zig:5097`)

- **签名**：`pub fn generatorStarted(self: *const Object) bool`。
- **作用**：查询 generator payload 的 started。
- **实现**：有 payload 返回字段，否则 false。
- **所有权 / 错误 / 调用**：不要求 execution 存在，不推进状态或执行相应动作。

### `Object.generatorJustYieldedSlot` (`src/core/object.zig:5102`)

- **签名**：`pub fn generatorJustYieldedSlot(self: *Object) *bool`。
- **作用**：借用 generator payload 的 just_yielded 可变槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配；直接写入不执行屏障或完成相关状态转换，调用方维护字段间不变量。

### `Object.generatorJustYielded` (`src/core/object.zig:5108`)

- **签名**：`pub fn generatorJustYielded(self: *const Object) bool`。
- **作用**：查询 generator payload 的 just_yielded。
- **实现**：有 payload 返回字段，否则 false。
- **所有权 / 错误 / 调用**：不要求 execution 存在，不推进状态或执行相应动作。

### `Object.generatorYieldStarSuspendedSlot` (`src/core/object.zig:5113`)

- **签名**：`pub fn generatorYieldStarSuspendedSlot(self: *Object) *bool`。
- **作用**：借用 generator payload 的 yield_star_suspended 可变槽。
- **实现**：有 payload 返回字段地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配；直接写入不执行屏障或完成相关状态转换，调用方维护字段间不变量。

### `Object.generatorYieldStarSuspended` (`src/core/object.zig:5119`)

- **签名**：`pub fn generatorYieldStarSuspended(self: *const Object) bool`。
- **作用**：查询 generator payload 的 yield_star_suspended。
- **实现**：有 payload 返回字段，否则 false。
- **所有权 / 错误 / 调用**：不要求 execution 存在，不推进状态或执行相应动作。

### `Object.generatorSuspendKindSlot` (`src/core/object.zig:5124`)

- **签名**：`pub fn generatorSuspendKindSlot(self: *Object) *u8`。
- **作用**：借用 generator payload 的 suspend_kind 字段槽。
- **实现**：有 payload 返回字段地址，否则断言 generator kind 后 unreachable。
- **所有权 / 错误 / 调用**：不验证枚举/容量或分配队列，不自动屏障；调用方须维护存储与状态协议。

### `Object.generatorSuspendKind` (`src/core/object.zig:5130`)

- **签名**：`pub fn generatorSuspendKind(self: *const Object) GeneratorSuspendKind`。
- **作用**：查询 generator 暂停类别。
- **实现**：有 payload 则 @enumFromInt(suspend_kind)，否则 .none。
- **所有权 / 错误 / 调用**：假定底层 u8 为有效枚举值，不校验或修复非法状态。

### `Object.asyncGeneratorStateSlot` (`src/core/object.zig:5135`)

- **签名**：`pub fn asyncGeneratorStateSlot(self: *Object) *u8`。
- **作用**：借用 generator payload 的 async_state 字段槽。
- **实现**：有 payload 返回字段地址，否则断言 generator kind 后 unreachable。
- **所有权 / 错误 / 调用**：不验证枚举/容量或分配队列，不自动屏障；调用方须维护存储与状态协议。

### `Object.asyncGeneratorQueueSlot` (`src/core/object.zig:5141`)

- **签名**：`pub fn asyncGeneratorQueueSlot(self: *Object) *[]AsyncGeneratorRequest`。
- **作用**：借用 generator payload 的 async_queue 字段槽。
- **实现**：有 payload 返回字段地址，否则断言 generator kind 后 unreachable。
- **所有权 / 错误 / 调用**：不验证枚举/容量或分配队列，不自动屏障；调用方须维护存储与状态协议。

### `Object.asyncGeneratorQueue` (`src/core/object.zig:5147`)

- **签名**：`pub fn asyncGeneratorQueue(self: *const Object) []AsyncGeneratorRequest`。
- **作用**：借用异步 generator 请求队列。
- **实现**：有 payload 返回 async_queue，否则空 slice。
- **所有权 / 错误 / 调用**：self const 仍返回可变元素，不 dequeue/排 job 或分配；写入须维护容量、GC 屏障与队列协议。

### `Object.asyncGeneratorQueueCapacitySlot` (`src/core/object.zig:5152`)

- **签名**：`pub fn asyncGeneratorQueueCapacitySlot(self: *Object) *usize`。
- **作用**：借用 generator payload 的 async_queue_capacity 字段槽。
- **实现**：有 payload 返回字段地址，否则断言 generator kind 后 unreachable。
- **所有权 / 错误 / 调用**：不验证枚举/容量或分配队列，不自动屏障；调用方须维护存储与状态协议。

### `Object.payloadSlot` (`src/core/object.zig:6300`)

- **签名**：`pub inline fn payloadSlot(self: *const Object) *class.Payload`。
- **作用**：借用对象头后固定偏移的 payload 指针槽。
- **实现**：返回 self 地址加 @sizeOf(Object) 后转换的 *class.Payload。
- **所有权 / 错误 / 调用**：self const 仍返回可变槽；没有 class/kind/layout 检查。slots2 对象必须先 spill inline properties 才能把此重叠区域用于 payload，本函数不执行 spill。

### `Object.injectSlots2PayloadArmMutationForTest` (`src/core/object.zig:6308`)

- **签名**：`pub fn injectSlots2PayloadArmMutationForTest(self: *Object) void`。
- **作用**：仅测试的 M-cut 变异注入：跳过 TGC S4-c 的 spill，使 slots2 对象的 payload 指针压在第一条 inline property entry 上，供 verifyObjectPropertyStorageLayouts 审计边界检出。
- **实现**：非测试构建 @compileError；gc.mCutInjection(2) 命中时调用 setPropertyStorageInline() 把属性存储指针改回尾部 inline 基址，未命中则无操作。
- **所有权 / 错误 / 调用**：不单独拥有堆；所有权在 Object/payload/Shape/runtime 侧表。


### `Object.ordinaryPayloadForAudit` (`src/core/object.zig:6314`)

- **签名**：`pub fn ordinaryPayloadForAudit(self: *const Object) ?*const OrdinaryPayload`。
- **作用**：为审计借用只读 ordinary payload。
- **实现**：直接返回 ordinaryPayloadConst()。
- **所有权 / 错误 / 调用**：不分配、验证 GC 全局状态或改变对象，只提供受 kind 合同约束的查询。

### `Object.promiseReactionRecordPayload` (`src/core/object.zig:6318`)

- **签名**：`fn promiseReactionRecordPayload(self: *Object) ?*PromiseReactionRecordPayload`。
- **作用**：按 kind 借用 PromiseReactionRecordPayload。
- **实现**：kind 不为 promise_reaction_record 返回 null；否则解包 payloadSlot 非空指针，再 alignCast/ptrCast。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空属于不变量违例，不能把 optional 返回理解为兼容该状态。返回可变 pointee。

### `Object.promiseReactionRecordPayloadConst` (`src/core/object.zig:6323`)

- **签名**：`fn promiseReactionRecordPayloadConst(self: *const Object) ?*const PromiseReactionRecordPayload`。
- **作用**：按 kind 借用 PromiseReactionRecordPayload。
- **实现**：kind 不为 promise_reaction_record 返回 null；否则解包 payloadSlot 非空指针，再 alignCast/ptrCast。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空属于不变量违例，不能把 optional 返回理解为兼容该状态。返回只读 pointee。

### `Object.ordinaryPayload` (`src/core/object.zig:6328`)

- **签名**：`fn ordinaryPayload(self: *const Object) ?*OrdinaryPayload`。
- **作用**：按 kind 借用 OrdinaryPayload。
- **实现**：kind 不为 ordinary 返回 null；否则解包 payloadSlot 非空指针，再 alignCast/ptrCast。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空属于不变量违例，不能把 optional 返回理解为兼容该状态。返回可变 pointee。

### `Object.ordinaryPayloadConst` (`src/core/object.zig:6333`)

- **签名**：`fn ordinaryPayloadConst(self: *const Object) ?*const OrdinaryPayload`。
- **作用**：按 kind 借用 OrdinaryPayload。
- **实现**：kind 不为 ordinary 返回 null；否则解包 payloadSlot 非空指针，再 alignCast/ptrCast。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空属于不变量违例，不能把 optional 返回理解为兼容该状态。返回只读 pointee。

### `Object.iteratorPayload` (`src/core/object.zig:6338`)

- **签名**：`fn iteratorPayload(self: *Object) ?*IteratorPayload`。
- **作用**：按 kind 查询 iterator payload。
- **实现**：kind 非 iterator 或 payloadArm 指针为空返回 null，否则转换指针。
- **所有权 / 错误 / 调用**：与 ordinary payload 不同，匹配 kind 时空指针也返回 null；不分配或检查 class，返回可变借用。

### `Object.iteratorPayloadConst` (`src/core/object.zig:6344`)

- **签名**：`fn iteratorPayloadConst(self: *const Object) ?*const IteratorPayload`。
- **作用**：按 kind 查询 iterator payload。
- **实现**：kind 非 iterator 或 payloadArm 指针为空返回 null，否则转换指针。
- **所有权 / 错误 / 调用**：与 ordinary payload 不同，匹配 kind 时空指针也返回 null；不分配或检查 class，返回只读借用。

### `Object.releaseIteratorCollectionCursor` (`src/core/object.zig:6355`)

- **签名**：`fn releaseIteratorCollectionCursor(class_id: class.ClassId, payload: *IteratorPayload) void`。
- **作用**：归还 Map/Set iterator 已持有的 collection cursor。
- **实现**：未 held 则返回；先清 held，再检查 map/set iterator class、非空 target 和 objectFromValue；都满足才 target.releaseCollectionCursor。
- **所有权 / 错误 / 调用**：不清 target、不释放 payload 或 RC 引用；即使 class/target 不符合，held 也已清除。只归还一次游标计数，不验证目标 collection 的完整语义。

### `Object.destroyIteratorPayload` (`src/core/object.zig:6364`)

- **签名**：`fn destroyIteratorPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 iterator payload 挂接后销毁其资源与分配。
- **实现**：无 payload 返回；先 releaseIteratorCollectionCursor，再清 arm、置 kind none，调用 payload.destroy(rt)，最后 memory.destroy(IteratorPayload)。
- **所有权 / 错误 / 调用**：对象字段先清空再进入资源销毁，避免仍暴露旧 payload；不等于销毁整个 Object 或注销所有 runtime 侧表。

### `Object.collectionPayload` (`src/core/object.zig:6373`)

- **签名**：`fn collectionPayload(self: *Object) ?*CollectionPayload`。
- **作用**：按 kind 借用 CollectionPayload。
- **实现**：kind 非 collection 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 13 处调用，文件外无调用方。`CollectionPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyCollectionPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。跨文件只能经 pub 包装 `collectionPayloadForCycleGc` 进来，那是周期 GC 处理弱边的窄出口。

### `Object.collectionPayloadForCycleGc` (`src/core/object.zig:6380`)

- **签名**：`pub fn collectionPayloadForCycleGc(self: *Object) ?*CollectionPayload`。
- **作用**：向跨文件弱引用处理提供 payload 借用。
- **实现**：直接委托 collectionPayload()。
- **所有权 / 错误 / 调用**：本函数自身不执行 GC、扫描或改变弱目标；返回可变可选指针。

### `Object.collectionPayloadConst` (`src/core/object.zig:6384`)

- **签名**：`fn collectionPayloadConst(self: *const Object) ?*const CollectionPayload`。
- **作用**：按 kind 借用 CollectionPayload。
- **实现**：kind 非 collection 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 11 处调用，文件外无调用方。`CollectionPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyCollectionPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。返回只读借用；写路径另走可变版本。

### `Object.destroyCollectionPayload` (`src/core/object.zig:6390`)

- **签名**：`fn destroyCollectionPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 CollectionPayload 挂接后清理资源并释放分配。
- **实现**：调用 collectionPayload，无 payload 返回；先 arm=null、kind=none，再 payload.destroy(rt)，最后 memory.destroy(CollectionPayload)。
- **所有权 / 错误 / 调用**：先断开对象字段，再执行 payload 自身的资源清理；不销毁 Object 本体，也不替代外层 holder/GC 注册表注销。

### `Object.finalizationRegistryPayload` (`src/core/object.zig:6398`)

- **签名**：`fn finalizationRegistryPayload(self: *Object) ?*FinalizationRegistryPayload`。
- **作用**：按 kind 借用 FinalizationRegistryPayload。
- **实现**：kind 非 finalization_registry 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 9 处调用，文件外无调用方。`FinalizationRegistryPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyFinalizationRegistryPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。跨文件只能经 pub 包装 `finalizationRegistryPayloadForCycleGc` 进来，那是周期 GC 处理弱边的窄出口。

### `Object.finalizationRegistryPayloadForCycleGc` (`src/core/object.zig:6405`)

- **签名**：`pub fn finalizationRegistryPayloadForCycleGc(self: *Object) ?*FinalizationRegistryPayload`。
- **作用**：向跨文件弱引用处理提供 payload 借用。
- **实现**：直接委托 finalizationRegistryPayload()。
- **所有权 / 错误 / 调用**：本函数自身不执行 GC、扫描或改变弱目标；返回可变可选指针。

### `Object.finalizationRegistryPayloadConst` (`src/core/object.zig:6409`)

- **签名**：`fn finalizationRegistryPayloadConst(self: *const Object) ?*const FinalizationRegistryPayload`。
- **作用**：按 kind 借用 FinalizationRegistryPayload。
- **实现**：kind 非 finalization_registry 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 8 处调用，文件外无调用方。`FinalizationRegistryPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyFinalizationRegistryPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。返回只读借用。

### `Object.destroyFinalizationRegistryPayload` (`src/core/object.zig:6415`)

- **签名**：`fn destroyFinalizationRegistryPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 FinalizationRegistryPayload 挂接后清理资源并释放分配。
- **实现**：调用 finalizationRegistryPayload，无 payload 返回；先 arm=null、kind=none，再 payload.destroy(rt)，最后 memory.destroy(FinalizationRegistryPayload)。
- **所有权 / 错误 / 调用**：先断开对象字段，再执行 payload 自身的资源清理；不销毁 Object 本体，也不替代外层 holder/GC 注册表注销。

### `Object.weakRefPayload` (`src/core/object.zig:6423`)

- **签名**：`fn weakRefPayload(self: *Object) ?*WeakRefPayload`。
- **作用**：按 kind 借用 WeakRefPayload。
- **实现**：kind 非 weak_ref 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 6 处调用，文件外无调用方。`WeakRefPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyWeakRefPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。跨文件只能经 pub 包装 `weakRefPayloadForCycleGc` 进来，那是周期 GC 处理弱边的窄出口。

### `Object.weakRefPayloadForCycleGc` (`src/core/object.zig:6430`)

- **签名**：`pub fn weakRefPayloadForCycleGc(self: *Object) ?*WeakRefPayload`。
- **作用**：向跨文件弱引用处理提供 payload 借用。
- **实现**：直接委托 weakRefPayload()。
- **所有权 / 错误 / 调用**：本函数自身不执行 GC、扫描或改变弱目标；返回可变可选指针。

### `Object.weakRefPayloadConst` (`src/core/object.zig:6434`)

- **签名**：`fn weakRefPayloadConst(self: *const Object) ?*const WeakRefPayload`。
- **作用**：按 kind 借用 WeakRefPayload。
- **实现**：kind 非 weak_ref 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 4 处调用，文件外无调用方。`WeakRefPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyWeakRefPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。返回只读借用。

### `Object.destroyWeakRefPayload` (`src/core/object.zig:6440`)

- **签名**：`fn destroyWeakRefPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 WeakRefPayload 挂接后清理资源并释放分配。
- **实现**：调用 weakRefPayload，无 payload 返回；先 arm=null、kind=none，再 payload.destroy(rt)，最后 memory.destroy(WeakRefPayload)。
- **所有权 / 错误 / 调用**：先断开对象字段，再执行 payload 自身的资源清理；不销毁 Object 本体，也不替代外层 holder/GC 注册表注销。

### `Object.isWeakReferenceHolderClass` (`src/core/object.zig:6448`)

- **签名**：`pub fn isWeakReferenceHolderClass(self: *const Object) bool`。
- **作用**：判断 class 是否属于四类弱引用 holder。
- **实现**：weakmap、weakset、weak_ref、finalization_registry 返回 true，其他 false。
- **所有权 / 错误 / 调用**：只按 class，不检查 payload、非空弱条目或 runtime 注册状态。

### `Object.weakReferenceHolderLink` (`src/core/object.zig:6455`)

- **签名**：`pub fn weakReferenceHolderLink(self: *Object) ?*WeakReferenceHolderLink`。
- **作用**：取得 payload 内嵌的 weak holder link。
- **实现**：依次尝试 collection、weakRef、finalizationRegistry payload，返回第一个匹配的 weak_holder_link 地址，否则 null。
- **所有权 / 错误 / 调用**：不调用 isWeakReferenceHolderClass，因此普通强 collection payload 也能提供 link；不等价于已登记 runtime 弱链表。返回可变借用。

### `Object.weakReferenceHolderLinkConst` (`src/core/object.zig:6462`)

- **签名**：`pub fn weakReferenceHolderLinkConst(self: *const Object) ?*const WeakReferenceHolderLink`。
- **作用**：取得 payload 内嵌的 weak holder link。
- **实现**：依次尝试 collection、weakRef、finalizationRegistry payload，返回第一个匹配的 weak_holder_link 地址，否则 null。
- **所有权 / 错误 / 调用**：不调用 isWeakReferenceHolderClass，因此普通强 collection payload 也能提供 link；不等价于已登记 runtime 弱链表。返回只读借用。

### `Object.weakReferenceHolderPrevious` (`src/core/object.zig:6469`)

- **签名**：`pub fn weakReferenceHolderPrevious(self: *const Object) ?*Object`。
- **作用**：查询 weak holder link 的 previous 指针。
- **实现**：weakReferenceHolderLinkConst 缺失返回 null，否则返回对应字段。
- **所有权 / 错误 / 调用**：不验证邻居反向链或 registered 状态，不遍历整个链表。

### `Object.weakReferenceHolderNext` (`src/core/object.zig:6474`)

- **签名**：`pub fn weakReferenceHolderNext(self: *const Object) ?*Object`。
- **作用**：查询 weak holder link 的 next 指针。
- **实现**：weakReferenceHolderLinkConst 缺失返回 null，否则返回对应字段。
- **所有权 / 错误 / 调用**：不验证邻居反向链或 registered 状态，不遍历整个链表。

### `Object.stdFilePayload` (`src/core/object.zig:6479`)

- **签名**：`fn stdFilePayload(self: *Object) ?*StdFilePayload`。
- **作用**：按 kind 借用 StdFilePayload。
- **实现**：kind 非 std_file 或 payloadArm 为空返回 null，否则转换指针。
- **所有权 / 错误 / 调用**：不检查文件是否打开或关闭文件，也不创建 payload。

### `Object.destroyStdFilePayload` (`src/core/object.zig:6485`)

- **签名**：`fn destroyStdFilePayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：销毁 std_file payload 及分配。
- **实现**：无 payload 返回；先清 arm 和 kind，再 payload.destroy()，最后 memory.destroy(StdFilePayload)。
- **所有权 / 错误 / 调用**：此 helper 本身不 enqueue deferred close，payload.destroy() 也只把三个字段复位为默认值、并不关闭 FILE*；真正的关闭由析构路径更早的 enqueueDeferredStdFileClose 负责。不销毁 Object。

### `Object.disposableStackPayload` (`src/core/object.zig:6493`)

- **签名**：`fn disposableStackPayload(self: *Object) ?*DisposableStackPayload`。
- **作用**：按 kind 借用 DisposableStackPayload。
- **实现**：kind 非 disposable_stack 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 10 处调用，文件外无调用方。`DisposableStackPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyDisposableStackPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。

### `Object.disposableStackPayloadConst` (`src/core/object.zig:6499`)

- **签名**：`fn disposableStackPayloadConst(self: *const Object) ?*const DisposableStackPayload`。
- **作用**：按 kind 借用 DisposableStackPayload。
- **实现**：kind 非 disposable_stack 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 3 处调用，文件外无调用方。`DisposableStackPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyDisposableStackPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。返回只读借用。

### `Object.globalPayload` (`src/core/object.zig:6505`)

- **签名**：`fn globalPayload(self: *Object) ?*GlobalPayload`。
- **作用**：按 kind 借用 GlobalPayload。
- **实现**：kind 非 global 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 2 处调用，文件外无调用方。`GlobalPayload` 由 `ensureGlobalPayload` 惰性 `createPayloadCell` 铸出（`payloadKindAllocates(.global)` 是 false，构造期不建），是 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyGlobalPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。

### `Object.globalPayloadConst` (`src/core/object.zig:6511`)

- **签名**：`fn globalPayloadConst(self: *const Object) ?*const GlobalPayload`。
- **作用**：按 kind 借用 GlobalPayload。
- **实现**：kind 非 global 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 2 处调用，文件外无调用方。`GlobalPayload` 由 `ensureGlobalPayload` 惰性铸出，是 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyGlobalPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。返回只读借用；没 ensure 过的 global 在这里就是 null。

### `Object.destroyRealmRecordPayload` (`src/core/object.zig:6517`)

- **签名**：`fn destroyRealmRecordPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：销毁 realm_record payload 及 runtime 分配。
- **实现**：kind 不符或 arm 空返回；转换 payload，先清 arm/kind，再 payload.destroy()，最后 rt.destroyRuntime。
- **所有权 / 错误 / 调用**：不是 ordinary payload GC cell 的回收路径；RealmRef 清理遵循当前 tracing 指针语义，不应描述为 RC 递减立即销毁 realm。

### `Object.bufferPayload` (`src/core/object.zig:6527`)

- **签名**：`fn bufferPayload(self: *Object) ?*BufferPayload`。
- **作用**：按 kind 借用 BufferPayload。
- **实现**：kind 非 buffer 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 11 处调用，文件外无调用方。`BufferPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyBufferPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。`BufferPayload.destroy` 还要还掉外部字节缓冲，所以它属于必须留 finalizer 的 b 类。

### `Object.bufferPayloadConst` (`src/core/object.zig:6533`)

- **签名**：`fn bufferPayloadConst(self: *const Object) ?*const BufferPayload`。
- **作用**：按 kind 借用 BufferPayload。
- **实现**：kind 非 buffer 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 5 处调用，文件外无调用方。`BufferPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyBufferPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。返回只读借用。

### `Object.destroyBufferPayload` (`src/core/object.zig:6539`)

- **签名**：`fn destroyBufferPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 BufferPayload 挂接后清理资源并释放分配。
- **实现**：调用 bufferPayload，无 payload 返回；先 arm=null、kind=none，再 payload.destroy(rt)，最后 memory.destroy(BufferPayload)。
- **所有权 / 错误 / 调用**：先断开对象字段，再执行 payload 自身的资源清理；不销毁 Object 本体，也不替代外层 holder/GC 注册表注销。

### `Object.typedArrayPayload` (`src/core/object.zig:6547`)

- **签名**：`fn typedArrayPayload(self: *Object) ?*TypedArrayPayload`。
- **作用**：按 kind 借用 TypedArrayPayload。
- **实现**：kind 非 typed_array 返回 null，否则直接解包 payloadArm 非空指针并转换类型。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空是不变量违例，不走 null 返回分支；返回可变借用，不分配或验证语义 class。

### `Object.typedArrayPayloadConst` (`src/core/object.zig:6552`)

- **签名**：`fn typedArrayPayloadConst(self: *const Object) ?*const TypedArrayPayload`。
- **作用**：按 kind 借用 TypedArrayPayload。
- **实现**：kind 非 typed_array 返回 null，否则直接解包 payloadArm 非空指针并转换类型。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空是不变量违例，不走 null 返回分支；返回只读借用，不分配或验证语义 class。

### `Object.destroyTypedArrayPayload` (`src/core/object.zig:6557`)

- **签名**：`fn destroyTypedArrayPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 TypedArrayPayload 挂接后清理资源并释放分配。
- **实现**：调用 typedArrayPayload，无 payload 返回；先 arm=null、kind=none，再 payload.destroy(rt)，最后 memory.destroy(TypedArrayPayload)。
- **所有权 / 错误 / 调用**：先断开对象字段，再执行 payload 自身的资源清理；不销毁 Object 本体，也不替代外层 holder/GC 注册表注销。

### `Object.regExpPayload` (`src/core/object.zig:6565`)

- **签名**：`fn regExpPayload(self: *Object) ?*RegExpPayload`。
- **作用**：取得 inline 或外置 RegExpPayload。
- **实现**：kind 非 regexp 返回 null；class==regexp 则返回 regexpArm 地址，否则读取 payloadArm，空返回 null，非空转换。
- **所有权 / 错误 / 调用**：builtin RegExp 的 union 内容是 inline payload，不是可独立 free 的 payload 指针。返回可变借用。

### `Object.regExpPayloadConst` (`src/core/object.zig:6572`)

- **签名**：`fn regExpPayloadConst(self: *const Object) ?*const RegExpPayload`。
- **作用**：取得 inline 或外置 RegExpPayload。
- **实现**：kind 非 regexp 返回 null；class==regexp 则返回 regexpArm 地址，否则读取 payloadArm，空返回 null，非空转换。
- **所有权 / 错误 / 调用**：builtin RegExp 的 union 内容是 inline payload，不是可独立 free 的 payload 指针。返回只读借用。

### `Object.boundFunctionPayload` (`src/core/object.zig:6579`)

- **签名**：`fn boundFunctionPayload(self: *Object) ?*BoundFunctionPayload`。
- **作用**：按 kind 借用 BoundFunctionPayload。
- **实现**：kind 非 bound_function 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 4 处调用，文件外无调用方。`BoundFunctionPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyBoundFunctionPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。

### `Object.boundFunctionPayloadConst` (`src/core/object.zig:6585`)

- **签名**：`fn boundFunctionPayloadConst(self: *const Object) ?*const BoundFunctionPayload`。
- **作用**：按 kind 借用 BoundFunctionPayload。
- **实现**：kind 非 bound_function 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 4 处调用，文件外无调用方。`BoundFunctionPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyBoundFunctionPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。返回只读借用。

### `Object.proxyPayload` (`src/core/object.zig:6591`)

- **签名**：`fn proxyPayload(self: *Object) ?*ProxyPayload`。
- **作用**：按 kind 借用 ProxyPayload。
- **实现**：kind 非 proxy 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 4 处调用，文件外无调用方。`ProxyPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyProxyPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。

### `Object.proxyPayloadConst` (`src/core/object.zig:6597`)

- **签名**：`fn proxyPayloadConst(self: *const Object) ?*const ProxyPayload`。
- **作用**：按 kind 借用 ProxyPayload。
- **实现**：kind 非 proxy 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 3 处调用，文件外无调用方。`ProxyPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyProxyPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。返回只读借用。

### `Object.argumentsPayload` (`src/core/object.zig:6603`)

- **签名**：`fn argumentsPayload(self: *Object) ?*ArgumentsPayload`。
- **作用**：按 kind 借用 ArgumentsPayload。
- **实现**：kind 非 arguments 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 1 处调用，文件外无调用方。`ArgumentsPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyArgumentsPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。

### `Object.argumentsPayloadConst` (`src/core/object.zig:6609`)

- **签名**：`fn argumentsPayloadConst(self: *const Object) ?*const ArgumentsPayload`。
- **作用**：按 kind 借用 ArgumentsPayload。
- **实现**：kind 非 arguments 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 1 处调用，文件外无调用方。`ArgumentsPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyArgumentsPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。返回只读借用。

### `Object.objectDataPayload` (`src/core/object.zig:6615`)

- **签名**：`fn objectDataPayload(self: *Object) ?*ObjectDataPayload`。
- **作用**：按 kind 借用 ObjectDataPayload。
- **实现**：kind 非 object_data 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 2 处调用，文件外无调用方。`ObjectDataPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyObjectDataPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。

### `Object.objectDataPayloadConst` (`src/core/object.zig:6621`)

- **签名**：`fn objectDataPayloadConst(self: *const Object) ?*const ObjectDataPayload`。
- **作用**：按 kind 借用 ObjectDataPayload。
- **实现**：kind 非 object_data 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 2 处调用，文件外无调用方。`ObjectDataPayload` 是构造时 `allocClassPayloadCell` 铸出来的 `.payload` GC cell（`payloadKindIsTracerOwnedCell` 里的 a 类）：没有 `destroyObjectDataPayload`，`freeClassPayloadAllocation` 对应臂也是空的，由 sweep 直接回收，所以返回的借用指针只在对象存活期内有效。返回只读借用。

### `Object.varRefPayload` (`src/core/object.zig:6627`)

- **签名**：`fn varRefPayload(self: *Object) ?*VarRefPayload`。
- **作用**：按 kind 借用 VarRefPayload。
- **实现**：kind 非 var_ref 返回 null，否则直接解包 payloadArm 非空指针并转换类型。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空是不变量违例，不走 null 返回分支；返回可变借用，不分配或验证语义 class。

### `Object.varRefPayloadConst` (`src/core/object.zig:6632`)

- **签名**：`fn varRefPayloadConst(self: *const Object) ?*const VarRefPayload`。
- **作用**：按 kind 借用 VarRefPayload。
- **实现**：kind 非 var_ref 返回 null，否则直接解包 payloadArm 非空指针并转换类型。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空是不变量违例，不走 null 返回分支；返回只读借用，不分配或验证语义 class。

### `Object.promisePayload` (`src/core/object.zig:6637`)

- **签名**：`pub fn promisePayload(self: *Object) ?*PromisePayload`。
- **作用**：按 kind 借用 PromisePayload。
- **实现**：kind 非 promise 返回 null，否则直接解包 payloadArm 非空指针并转换类型。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空是不变量违例，不走 null 返回分支；返回可变借用，不分配或验证语义 class。

### `Object.promisePayloadConst` (`src/core/object.zig:6642`)

- **签名**：`fn promisePayloadConst(self: *const Object) ?*const PromisePayload`。
- **作用**：按 kind 借用 PromisePayload。
- **实现**：kind 非 promise 返回 null，否则直接解包 payloadArm 非空指针并转换类型。
- **所有权 / 错误 / 调用**：kind 匹配却指针为空是不变量违例，不走 null 返回分支；返回只读借用，不分配或验证语义 class。

### `Object.generatorPayload` (`src/core/object.zig:6647`)

- **签名**：`fn generatorPayload(self: *Object) ?*GeneratorPayload`。
- **作用**：按 kind 借用 GeneratorPayload。
- **实现**：kind 非 generator 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 20 处调用，文件外无调用方。`GeneratorPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyGeneratorPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。构造中途失败时另由 `freeClassPayloadAllocation` 的 `.generator` 臂做同样的 destroy+free。

### `Object.generatorPayloadConst` (`src/core/object.zig:6653`)

- **签名**：`fn generatorPayloadConst(self: *const Object) ?*const GeneratorPayload`。
- **作用**：按 kind 借用 GeneratorPayload。
- **实现**：kind 非 generator 或 payloadArm 指针为空均返回 null，否则 alignCast/ptrCast 为相应类型。
- **所有权 / 错误 / 调用**：私有 `fn`，不分配也没有 error set，只按 `class_payload_kind` 判别再 ptrCast；object.zig 内共 18 处调用，文件外无调用方。`GeneratorPayload` 由 `rt.memory` 分配，`destroyClassPayload` 经 `destroyGeneratorPayload` 先清 arm 与 kind、再 `payload.destroy(rt)` + `rt.memory.destroy` 释放，对象析构后这个借用指针立即悬空。返回只读借用；`asyncGeneratorQueue` 等读访问器都走这一条。

### `Object.destroyGeneratorPayload` (`src/core/object.zig:6659`)

- **签名**：`fn destroyGeneratorPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：解除 GeneratorPayload 挂接后清理资源并释放分配。
- **实现**：调用 generatorPayload，无 payload 返回；先 arm=null、kind=none，再 payload.destroy(rt)，最后 memory.destroy(GeneratorPayload)。
- **所有权 / 错误 / 调用**：先断开对象字段，再执行 payload 自身的资源清理；不销毁 Object 本体，也不替代外层 holder/GC 注册表注销。

### `Object.functionPayload` (`src/core/object.zig:6667`)

- **签名**：`fn functionPayload(self: *Object) ?*FunctionPayload`。
- **作用**：查询非字节码函数的外置 FunctionPayload。
- **实现**：kind 非 function 或属于字节码函数 class 返回 null；否则解包 payloadArm 非空指针并转换。
- **所有权 / 错误 / 调用**：字节码函数改用专属 inline arm；kind/class 匹配的 native payload 不允许空指针。返回可变借用。

### `Object.functionPayloadConst` (`src/core/object.zig:6673`)

- **签名**：`fn functionPayloadConst(self: *const Object) ?*const FunctionPayload`。
- **作用**：查询非字节码函数的外置 FunctionPayload。
- **实现**：kind 非 function 或属于字节码函数 class 返回 null；否则解包 payloadArm 非空指针并转换。
- **所有权 / 错误 / 调用**：字节码函数改用专属 inline arm；kind/class 匹配的 native payload 不允许空指针。返回只读借用。

### `Object.destroyFunctionPayload` (`src/core/object.zig:6679`)

- **签名**：`fn destroyFunctionPayload(self: *Object, rt: *JSRuntime) void`。
- **作用**：分别清理字节码函数 inline arm 或 native function payload。
- **实现**：字节码 class：var_refs 置 sentinel，有 aux 则先清 home_or_aux 再 aux.destroy，无 aux 的 direct home 也清空；最后清 fb/kind。其他 class：查询 function payload，清 arm/kind 后 destroyNative，再 memory.destroy。
- **所有权 / 错误 / 调用**：字节码 capture array 和 aux 是 GC cell，不手动 free；native payload 则显式释放分配。字节码分支仅按 class 进入，调用方须保证对应 arm 合同。

## 覆盖核对

- 清单函数数（本文件分到）: 347（`src/core/object.zig` 全文件 873）
- 本文标题覆盖: 347
- 未覆盖: 无
