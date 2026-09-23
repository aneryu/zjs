# 07 — 对象分配与构造（`src/core/object.zig`）

`create*` 族、cell 尺寸、a/b/c 类 payload 的 mint/free、inline embedder payload、Array 构造。布局见 [07-core-object.md](07-core-object.md)。

构造路径先准备 Shape 与资源 payload，再执行对象分配前的 GC 边界；需要的 `.property_storage` 与 a 类 `.payload` cell 在 Object cell 前创建，随后初始化并登记。不能把这一顺序简化为“GC 边界后没有失败”：storage/cell 分配、动态 class 的 authority 准备及登记仍有错误路径。裸 GC cell 从创建到安装期间必须满足存活协议，具体分支及失败清理见 createInternal 等条目。

---


### `Object.expect` (`src/core/object.zig:867`)

- **签名**：`pub fn expect(val: JSValue) !*Object`。
- **作用**：将JSValue按Object类型要求转换为对象指针。
- **实现**：refHeader为空返回TypeError，再isObject为false返回TypeError，否则fromHeader。
- **所有权 / 错误 / 调用**：不做ToObject装箱；借用指针，不新建对象或pin。

### `Object.create` (`src/core/object.zig:873`)

- **签名**：`pub fn create(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object) !*Object`。
- **作用**：按class选择普通Object专用构造或通用构造。
- **实现**：class为object调用createPlainObject(rt,prototype)；其它调用createInternal(rt,class_id,prototype,0,null)。
- **所有权 / 错误 / 调用**：返回已由相应构造路径初始化并登记的对象，不是只分配raw cell；错误由具体构造路径传播。

### `Object.createFinalizationRegistry` (`src/core/object.zig:888`)

- **签名**：`pub fn createFinalizationRegistry( rt: *JSRuntime, realm: *context_mod.RealmContext, prototype: ?*Object, ) !*Object`。
- **作用**：创建FinalizationRegistry并在返回前安装所属Realm引用。
- **实现**：断言realm.runtime==rt；先createInternal对应class，再取payload并断言其realm为空，赋RealmRef.retain(realm)，返回registry。
- **所有权 / 错误 / 调用**：createInternal内部已registerObjectWithBytes，因此Realm安装在GC登记之后、返回调用者之前，不能照旧注释写为GC发布之前。retain这一步无error返回；不建立另一份payload或宿主pin。

### `Object.createWithOwnPropertyCapacity` (`src/core/object.zig:901`)

- **签名**：`pub fn createWithOwnPropertyCapacity(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, capacity: usize) !*Object`。
- **作用**：通过通用构造入口请求初始own-property容量。
- **实现**：调用createInternal(rt,class_id,prototype,capacity,null)。
- **所有权 / 错误 / 调用**：不同于create，不对plain Object先分派专用入口；capacity是容量请求，不代表创建同等数量可枚举属性。

### `Object.reserveOwnPropertyCapacity` (`src/core/object.zig:908`)

- **签名**：`pub fn reserveOwnPropertyCapacity(self: *Object, rt: *JSRuntime, needed: usize) !void`。
- **作用**：确保对象可容纳所需命名属性槽容量。
- **实现**：try ensurePropertyCapacity(rt,needed)。
- **所有权 / 错误 / 调用**：不能保证Shape完全不变：callee可能替换property storage并调用rt.shapes.reserveProperties。后者失败时新buffer已安装，函数不是完整回滚事务；不新增属性名或增加prop_count。

### `Object.createGeneratorShell` (`src/core/object.zig:923`)

- **签名**：`pub fn createGeneratorShell(rt: *JSRuntime, class_id: class.ClassId) !*Object`。
- **作用**：创建受construction root保护、尚未GC发布的generator壳。
- **实现**：断言generator/async_generator，取标准class计划并核对generator payload；先分配并默认初始化GeneratorPayload，预留construction root槽，执行对象分配边界，再allocCell。初始化class/flags、空property指针及payload臂，shape_ref刻意undefined，设置needs_finalizer并addConstructionRoot，返回。
- **所有权 / 错误 / 调用**：失败按errdefer释放payload与raw cell。没有Shape、未heap_accounted，不能当完整JS对象读取；存活依赖construction-root特殊追踪，不是已退役RC。后续必须finishGeneratorShell或destroyGeneratorShell；执行记录的进一步配置由调用方完成。

### `Object.finishGeneratorShell` (`src/core/object.zig:982`)

- **签名**：`pub fn finishGeneratorShell(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void`。
- **作用**：给未发布generator壳安装最终Shape并正式登记。
- **实现**：断言class/payload及未accounted；createObjectRoot(prototype)，安装空Shape后removeConstructionRoot，try registerObjectWithBytes(bodyBytes)。登记失败仅清低七位Shape摘要、保留remembered高位，重新addConstructionRoot，shape置undefined并dropUnshared(final_shape)，返回错误。成功后attachGeneratorOpenVarRefOwners。
- **所有权 / 错误 / 调用**：Shape创建失败保持原shell；register失败恢复construction协议但不是清空所有prefix状态。open VarRef owner边在发布成功后安装，不能沿用fresh-header rc==1作为当前机制说明。

### `Object.destroyGeneratorShell` (`src/core/object.zig:1010`)

- **签名**：`pub fn destroyGeneratorShell(self: *Object, rt: *JSRuntime) void`。
- **作用**：清理尚未正式发布的generator壳及其payload。
- **实现**：断言generator类和未accounted，移除construction root；若borrowed holder则注销。freeClassPayloadAllocation按generator分支销毁执行资源并释放payload，随后清payload槽/kind，freeRawCell按原class无slots2布局释放对象。
- **所有权 / 错误 / 调用**：不读undefined Shape，也不走普通已发布对象unregister路径；仅适用于未finish成功的shell，重复调用或用于published对象违反合同。

### `Object.createFromPropertyTemplate` (`src/core/object.zig:1031`)

- **签名**：`pub fn createFromPropertyTemplate(rt: *JSRuntime, template: *const Object) !*Object`。
- **作用**：用模板的class、Shape及属性槽创建新对象。
- **实现**：断言模板非Array、非Proxy、非borrowed holder，再以template.propertyEntries调用createPreparedPropertyTemplate。
- **所有权 / 错误 / 调用**：不是完整克隆：dense元素、payload内容、extensible及其它flags不复制。helper另限定允许class和payload合同；Shape共享，属性Entry是浅复制，指向的值不会深克隆。

### `Object.createFromShape` (`src/core/object.zig:1040`)

- **签名**：`pub fn createFromShape( rt: *JSRuntime, class_id: class.ClassId, shape_ref: *shape.Shape, entries: []const property.Entry, ) !*Object`。
- **作用**：以指定Shape和对应属性槽通过通用构造创建对象。
- **实现**：断言entries.len==shape.prop_count，以Shape.proto/prop_size及PropertyTemplate调用createInternal。
- **所有权 / 错误 / 调用**：借用输入slice用于复制，Shape进入共享协议；不单凭class_id验证每个Entry与Shape flags匹配，调用者须提供合法布局。

### `Object.createArrayFromShape` (`src/core/object.zig:1053`)

- **签名**：`pub fn createArrayFromShape(rt: *JSRuntime, shape_ref: *shape.Shape, entries: []const property.Entry) !*Object`。
- **作用**：从Shape创建Array并建立dense初始模式。
- **实现**：entries.len和prop_count均0时走createArrayFromInitialShape；其它调用createFromShape(Array)，成功后设置fast_array=true。
- **所有权 / 错误 / 调用**：只复制命名属性，未提供dense元素；空数组专用路径与有命名属性的通用路径不同。

### `Object.createArrayFromInitialShape` (`src/core/object.zig:1078`)

- **签名**：`pub fn createArrayFromInitialShape(rt: *JSRuntime, initial_shape: *shape.Shape) !*Object`。
- **作用**：用空的realm初始Shape创建已登记的dense Array。
- **实现**：断言prop_count=0，Debug核对标准class计划，markShared。先执行对象GC边界，再按prop_size创建property storage，再allocCellConst。初始化array class、fast_array=true、无payload/exotic表，设置Shape与property指针，initArmPayload(null)清空dense元数据，登记Object后返回。
- **所有权 / 错误 / 调用**：property storage与Object是分别分配；失败时未关联storage由GC回收，不手动free。Object清理按initialized分支选raw free或destroyFromHeader。array索引/length exotic来自class语义，has_exotic_methods=false不表示普通对象语义。

### `Object.collectBeforeObjectAllocationPublishingShape` (`src/core/object.zig:1151`)

- **签名**：`fn collectBeforeObjectAllocationPublishingShape(rt: *JSRuntime, shape_ref: *shape.Shape, accounted_size: usize) void`。
- **作用**：在可重入分配边界前确保Shape已发布，并按构建模式建立局部根。
- **实现**：Shape未heap_accounted则rt.shapes.publish。非value_root_link_containers_only构建创建HeaderRootValue和ValueRootFrame，activate后在defer deactivate范围内调用collectBeforeObjectAllocation；另一分支直接调用。
- **所有权 / 错误 / 调用**：普通生产containers-only模式没有这里的标量header frame，不能宣称所有构建都显式pin；该模式依赖保守根及既有持有协议。只覆盖这次边界调用，不自动延长到构造后续全部分配。

### `Object.createPlainObject` (`src/core/object.zig:1188`)

- **签名**：`pub fn createPlainObject(rt: *JSRuntime, prototype: ?*Object) !*Object`。
- **作用**：创建无预留属性buffer的普通Object。
- **实现**：Debug核对class计划，取得reserved root Shape并设置失败dropUnshared。通过PublishingShape helper执行GC边界，再分配普通非slots2 cell；初始化class、无payload/exotic、Shape及空property哨兵，null payload臂，转移Shape清理责任后登记。
- **所有权 / 错误 / 调用**：没有为新{}分配Entry buffer，ordinary payload也延迟挂载；不应沿用旧注释固定64字节尺寸。失败按构造阶段清理，已发表但未拥有的GC资源由相应协议处理。

### `Object.createPlainObjectReserved2` (`src/core/object.zig:1243`)

- **签名**：`pub fn createPlainObjectReserved2(rt: *JSRuntime, prototype: ?*Object) !*Object`。
- **作用**：创建含两个内联属性槽容量的普通Object。
- **实现**：先取普通reserved root；prop_size非2则dropUnshared并改取精确容量2的root。边界发布/收集后allocCellConst slots2；先设slots2 flags再设置trailingPropertyStorageBase，保留prop_count=0并登记。
- **所有权 / 错误 / 调用**：只预留容量，不初始化两个可见属性或增加prop_count；slots2无普通payload臂，不调用initArmPayload。Shape容量与物理尾部必须一致，不能无条件复用任意同prototype空root。

### `Object.createRegExpFromShape` (`src/core/object.zig:1309`)

- **签名**：`pub fn createRegExpFromShape(rt: *JSRuntime, shape_ref: *shape.Shape) !*Object`。
- **作用**：用lastIndex初始槽创建RegExp对象。
- **实现**：断言Shape仅一个属性且atom为lastIndex；构造data=int32(0)的Entry数组，再createFromShape(regexp)。
- **所有权 / 错误 / 调用**：不编译pattern或设置regexp程序；属性flags来自输入Shape，此入口不验证其W/E/C全套属性。

### `Object.createRegExpMatchArrayFromShape` (`src/core/object.zig:1316`)

- **签名**：`pub fn createRegExpMatchArrayFromShape( rt: *JSRuntime, shape_ref: *shape.Shape, match_index: i32, input_value: JSValue, groups_value: JSValue, ) !*Object`。
- **作用**：用三个命名属性槽创建正则匹配结果Array。
- **实现**：断言Shape prop_count=3，依次构造match_index、input_value、groups_value的data Entry，再createArrayFromShape。
- **所有权 / 错误 / 调用**：本函数未检查三个属性名/flags，也未填充匹配字符串dense元素；输入JSValue浅复制，非深拷贝。

### `Object.createArgumentsFromShape` (`src/core/object.zig:1348`)

- **签名**：`pub fn createArgumentsFromShape( rt: *JSRuntime, class_id: class.ClassId, initial_shape: *shape.Shape, entries: []const property.Entry, ) !*Object`。
- **作用**：用准备好的命名属性槽构造Arguments或MappedArguments。
- **实现**：断言两种class、entries数等于prop_count且非空、capacity足够；Debug另核对标准class布局。markShared Shape，先对象分配边界，再property storage及Object cell。设payload none/exotic表false，初始化空臂，memcpy Entry并refresh摘要，登记后返回。
- **所有权 / 错误 / 调用**：fast_array保持默认false，dense或VarRef映射由后续调用方安装；不深复制槽中对象，也不验证每个属性名/flags。失败按initialized选择完整析构或raw cell释放，孤立property storage由GC处理。

### `createPreparedPropertyTemplate` (`src/core/object.zig:1431`)

- **签名**：`noinline fn createPreparedPropertyTemplate( rt: *JSRuntime, template: *const Object, entries: []const property.Entry, ) !*Object`。
- **作用**：直接复用准备好的模板Shape并浅复制其属性槽。
- **实现**：断言非Proxy/borrowed holder、payload无需分配、entries数量匹配，class限定Object/Array/两类Arguments。markShared Shape；先对象GC边界，再property storage及Object cell。仅复制class、has_exotic_methods、payload_kind与Shape，初始化空臂，memcpy Entry并refresh摘要，按条件stamp finalizer，登记。
- **所有权 / 错误 / 调用**：不复制模板其它flags、dense内容或class payload。输入Shape需由调用方协议保持可达；存储失败无手动free GC cell。初始化完成后的登记错误走destroyFromHeader，前期错误走raw cell清理。

### `Object.createInternal` (`src/core/object.zig:1506`)

- **签名**：`fn createInternal( rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, own_property_capacity: usize, property_template: ?PropertyTemplate, ) !*Object`。
- **作用**：按class定义、可选模板和容量构造并登记对象。
- **实现**：标准class按值取DefinitionPlan，动态class先beginConstruction并defer abort；计算inline布局和分配尺寸。模板使用共享Shape及prop_size，否则按容量选reserved root。内建RegExp/Promise、bytecode函数使用各自inline臂；其它需要payload的类型区分预先分配的资源payload与延迟GC payload cell。发布Shape并经过对象GC边界，先提交延迟payload分配压力，再property storage、payload cell和Object存储。inline动态payload走单独对齐raw分配及非block authority准备；其余allocCell。动态class publishObject后初始化head及相应臂，复制模板槽、初始化inline prefix/Shape摘要，转移清理责任，registerObjectWithBytes，按payload/class标析构责任并注册weak holder，最后返回。
- **所有权 / 错误 / 调用**：不是全体class都分配独立payload或property buffer，普通/全局payload可延迟。Shape与预分配资源payload各有errdefer；Object初始化前释放raw存储，初始化后由destroyFromHeader负责，避免重复清理。GC storage cell失败后不手动释放，由收集器处理。模板Entry是memcpy，不沿用旧RC注释中的逐槽dup；动态class构造保护也不是GC pin。NoTrigger内存入口仍可能有limit hook，不把源码注释中的“后续绝不收集”当作普遍接口保证。

### `Object.payloadKindAllocates` (`src/core/object.zig:1763`)

- **签名**：`inline fn payloadKindAllocates(payload_kind: class.PayloadKind) bool`。
- **作用**：判定通用构造是否需要处理该payload的分配分支。
- **实现**：none、ordinary、global返回false，其余true。
- **所有权 / 错误 / 调用**：不等于该类型永远没有payload；ordinary/global可懒创建，RegExp/Promise/bytecode还有构造端inline特例。

### `Object.payloadKindIsTracerOwnedCell` (`src/core/object.zig:1784`)

- **签名**：`pub inline fn payloadKindIsTracerOwnedCell(payload_kind: class.PayloadKind) bool`。
- **作用**：按payload kind分类无需资源析构的GC管理状态。
- **实现**：ordinary、promise_reaction_record、arguments、object_data、bound_function、proxy、var_ref、promise、disposable_stack、global、regexp为true，其余false。
- **所有权 / 错误 / 调用**：只看kind，不能证明具体实例确有独立cell；内建RegExp和Promise有inline存储。.function实际为false，不照旧注释写成bytecode function在此返回true。

### `Object.payloadKindIsTracerOwnedCellOrNone` (`src/core/object.zig:1818`)

- **签名**：`pub inline fn payloadKindIsTracerOwnedCellOrNone(payload_kind: class.PayloadKind) bool`。
- **作用**：将无payload和tracer-owned分类合并判断。
- **实现**：payload_kind==none或payloadKindIsTracerOwnedCell。
- **所有权 / 错误 / 调用**：不读取对象class或槽指针；不能据此断言u.payload实际指向GC cell。

### `Object.payloadKindNeedsFinalizer` (`src/core/object.zig:1830`)

- **签名**：`pub inline fn payloadKindNeedsFinalizer(class_id: class.ClassId, payload_kind: class.PayloadKind) bool`。
- **作用**：按class和payload种类判断payload是否需要显式析构。
- **实现**：function类型仅非bytecode函数class返回true；其余取!payloadKindIsTracerOwnedCellOrNone。
- **所有权 / 错误 / 调用**：只回答payload这部分责任；动态class回调、global borrowed清理、weak holder等还可要求对象finalizer，不能作完整对象免析构判据。

### `Object.markNeedsFinalizer` (`src/core/object.zig:1840`)

- **签名**：`pub inline fn markNeedsFinalizer(self: *Object, rt: *JSRuntime) void`。
- **作用**：为对象登记析构责任。
- **实现**：调用rt.gc.setNeedsFinalizer(self.gcHeader())。
- **所有权 / 错误 / 调用**：委托同时维护相应header/heap责任列，不立即执行回调；本函数只置位，旧责任消失后不自动清除。

### `Object.hasTracerOwnedPayloadCell` (`src/core/object.zig:1844`)

- **签名**：`pub inline fn hasTracerOwnedPayloadCell(self: *const Object) bool`。
- **作用**：判断当前payload状态是否按独立GC cell协议处理。
- **实现**：先按flags.class_payload_kind分类，不属tracer-owned则false；再排除class.ids.regexp及promise，其余true。
- **所有权 / 错误 / 调用**：不读取payload是否null，也不做地址验证；它是路线判别，不是具体非空已发布cell的成员证明。

### `Object.mintPayloadCell` (`src/core/object.zig:1856`)

- **签名**：`fn mintPayloadCell(rt: *JSRuntime, comptime T: type) !*T`。
- **作用**：分配已登记的payload GC cell并初始化其类型默认值。
- **实现**：编译期要求alignOf(T)<=8；createStorageCellPublished(payload kind,8+sizeOf(T))，转换body为*T后赋.{}。
- **所有权 / 错误 / 调用**：发布发生在默认值初始化之前，此间不得引入观察未初始化body的操作。没有主动requestGCForAllocation调用，但下层limit hook合同仍适用；返回后调用者及时安装owner边，不能把裸cell当持久精确根。

### `Object.createPayloadCell` (`src/core/object.zig:1870`)

- **签名**：`fn createPayloadCell(rt: *JSRuntime, comptime T: type) !*T`。
- **作用**：为懒挂载payload先报告分配压力再分配cell。
- **实现**：requestGCForAllocation(sizeOf(T))，随后mintPayloadCell(T)。
- **所有权 / 错误 / 调用**：压力尺寸不含prefix；不负责把payload挂到Object或执行该安装的屏障。

### `Object.payloadCellHeader` (`src/core/object.zig:1876`)

- **签名**：`pub inline fn payloadCellHeader(ptr: *anyopaque) *gc.Header`。
- **作用**：将payload cell body指针视作collector handle。
- **实现**：alignCast并ptrCast原指针。
- **所有权 / 错误 / 调用**：body与handle同址，不回退prefix；不验证kind、publication或分配归属，不建立pin。

### `Object.createPayloadSliceCell` (`src/core/object.zig:1888`)

- **签名**：`pub fn createPayloadSliceCell(rt: *JSRuntime, comptime T: type, capacity: usize) ![]T`。
- **作用**：为可变长payload元素数组申请GC storage cell。
- **实现**：编译期要求元素对齐<=8，断言capacity非0；checked乘法求body字节，checked加8求total，溢出OutOfMemory。先按body尺寸request压力，再createStorageCellPublished并转换为capacity长slice。
- **所有权 / 错误 / 调用**：元素未初始化，需调用者填写并及时安装可追踪owner边；增长时旧cell交GC，不用普通allocator.free。只断言capacity非零，不排除零尺寸T。

### `allocClassPayloadCell` (`src/core/object.zig:1908`)

- **签名**：`noinline fn allocClassPayloadCell(rt: *JSRuntime, payload_kind: class.PayloadKind) !class.Payload`。
- **作用**：按tracer-owned payload kind选择默认初始化的GC cell类型。
- **实现**：switch将ordinary/reaction/arguments/object_data/bound_function/proxy/var_ref/promise/disposable_stack/global/regexp映射到对应T并mintPayloadCell，其它unreachable。
- **所有权 / 错误 / 调用**：不自发压力请求，构造端需在持有第一个未安装cell之前统一请求；返回不等于已挂owner，类型错误不是可恢复错误。

### `Object.classPayloadCellBytes` (`src/core/object.zig:1927`)

- **签名**：`inline fn classPayloadCellBytes(payload_kind: class.PayloadKind) usize`。
- **作用**：查询tracer-owned payload kind的body尺寸。
- **实现**：与allocClassPayloadCell同一11种映射，返回sizeOf对应类型，其它unreachable。
- **所有权 / 错误 / 调用**：不含8字节prefix、class舍入或下属slice占用，用作分配压力估计。

### `allocFunctionPayload` (`src/core/object.zig:1948`)

- **签名**：`noinline fn allocFunctionPayload(rt: *JSRuntime) !class.Payload`。
- **作用**：为native function状态分配独立默认payload。
- **实现**：test或force_gc模式用rt.createRuntime(FunctionPayload)，其它用rt.memory.createNoTrigger；赋.{}并转class.Payload。
- **所有权 / 错误 / 调用**：并非bytecode函数inline臂的分配器；生产NoTrigger不排除limit hook。只分配状态，不安装function entry、realm或Object引用。

### `allocClassPayload` (`src/core/object.zig:1968`)

- **签名**：`noinline fn allocClassPayload(rt: *JSRuntime, payload_kind: class.PayloadKind) !class.Payload`。
- **作用**：分配需显式管理的class payload默认实例。
- **实现**：iterator/collection/buffer/typed_array/weak_ref/finalization_registry/realm_record分别createRuntime并赋.{}。generator另分配默认GeneratorExecutionState并挂payload.execution，第二次分配失败用errdefer释放payload；function及tracer-owned/none种类unreachable。
- **所有权 / 错误 / 调用**：不是所有分支都只有一笔分配；默认状态不等于资源已打开或完全业务初始化。失败不返回payload，generator回滚只需释放当时默认空payload。

### `freeClassPayloadAllocation` (`src/core/object.zig:2047`)

- **签名**：`noinline fn freeClassPayloadAllocation(rt: *JSRuntime, payload: class.Payload, payload_kind: class.PayloadKind) void`。
- **作用**：清理构造尚未交给Object析构负责的payload分配。
- **实现**：null返回；资源类型多数仅memory.destroy原类型，realm_record用destroyRuntime；generator先typed.destroy(rt)再memory.destroy；tracer-owned/none类无操作。
- **所有权 / 错误 / 调用**：与destroyDetachedClassPayload不同，除generator外不逐一调用资源destroy，依赖构造回滚时状态合同。GC cell由sweep处理；不能据旧注释声称它们之后没有任何fallible步骤。

### `Object.inlineClassPayloadLayout` (`src/core/object.zig:2084`)

- **签名**：`fn inlineClassPayloadLayout(maybe_record: ?*const class.Record) ?InlineClassPayloadLayout`。
- **作用**：从可选class记录取得内联payload布局。
- **实现**：记录null则null，否则将inline_payload_size/align交FromScalars。
- **所有权 / 错误 / 调用**：返回null也可能表示size0或计算溢出，不保留Record指针；没有检查具体class是不是允许的窄臂。

### `Object.inlineClassPayloadLayoutForDefinition` (`src/core/object.zig:2089`)

- **签名**：`fn inlineClassPayloadLayoutForDefinition(definition: class.Table.DefinitionPlan) ?InlineClassPayloadLayout`。
- **作用**：从稳定的class定义计划计算内联payload布局。
- **实现**：将definition的size/align交FromScalars。
- **所有权 / 错误 / 调用**：不查询动态class表，尺寸合法性由计划来源及辅助合同保证。

### `Object.inlineClassPayloadLayoutFromScalars` (`src/core/object.zig:2100`)

- **签名**：`fn inlineClassPayloadLayoutFromScalars(inline_payload_size: u32, inline_payload_align: u16) ?InlineClassPayloadLayout`。
- **作用**：计算raw分配起点、Object及内联payload的对齐布局。
- **实现**：size0返回null；payload对齐转Alignment，与Object对齐取大作allocation_alignment。object_offset将8向该对齐取整，payload_offset将inline_payload_body_bytes向payload对齐取整；checked相加得object_size及allocation_size，溢出null。
- **所有权 / 错误 / 调用**：inline_payload_body_bytes=24+8=32；offset相对Object或raw起点的含义不同。对齐须非零合法幂次，不是任意u16都安全返回null；不分配/初始化内存。

### `Object.initInlineClassPayloadGcPrefix` (`src/core/object.zig:2118`)

- **签名**：`fn initInlineClassPayloadGcPrefix(self: *Object) void`。
- **作用**：为raw aligned内联payload对象初始化standalone Metadata。
- **实现**：在self-8写默认Metadata并设standalone及Object kind。
- **所有权 / 错误 / 调用**：清新生状态但不初始化body/payload，不入账、不发布；只适用于新对象，不可覆盖已发布元数据。

### `Object.inlineClassPayloadPtr` (`src/core/object.zig:2127`)

- **签名**：`fn inlineClassPayloadPtr(self: *Object, layout: InlineClassPayloadLayout) *anyopaque`。
- **作用**：按布局借用Object内的payload地址。
- **实现**：self转byte pointer加layout.payload_offset。
- **所有权 / 错误 / 调用**：不清零、不验证size或对齐，不拥有独立分配；不得当独立payload cell或单独free。

### `Object.freeObjectAllocation` (`src/core/object.zig:2141`)

- **签名**：`inline fn freeObjectAllocation(rt: *JSRuntime, self: *Object, definition: class.Table.DefinitionPlan) void`。
- **作用**：按不可变定义与实际布局释放Object底层存储。
- **实现**：inline_payload_size非0走freeInlinePayloadObjectAllocation；否则slots2断言plain Object并destroyConstFam对应尾部；非slots2 plain用ConstFam，其它class用destroyWithFam计算尾部。
- **所有权 / 错误 / 调用**：不是总走slab，MemoryAccount按prefix区分block/slab/standalone。仅释放分配，要求先完成资源析构、Registry撤销与class生命周期协议。

### `Object.inlineClassObjectSize` (`src/core/object.zig:2174`)

- **签名**：`fn inlineClassObjectSize(definition: class.Table.DefinitionPlan) usize`。
- **作用**：快速计算内联payload Object的body尺寸。
- **实现**：编译期要求64位usize，断言payload size非0、align为2幂；将32对齐后加u32 payload size。
- **所有权 / 错误 / 调用**：不含Object前的padding/Metadata，不是raw free尺寸；利用64位及输入位宽范围而不返回可恢复溢出错误。

### `freeInlinePayloadObjectAllocation` (`src/core/object.zig:2159`)

- **签名**：`noinline fn freeInlinePayloadObjectAllocation(rt: *JSRuntime, self: *Object, definition: class.Table.DefinitionPlan) void`。
- **作用**：按完整raw布局释放带内联payload的对象。
- **实现**：重算layout或unreachable，self减object_offset恢复raw base；条件审计begin，freeAlignedBytes完整allocation_size/alignment，再finishExtentGcRawFree。
- **所有权 / 错误 / 调用**：Object大小与raw申请大小不同；不单独释放payload，也不从live class记录重查，而用传入DefinitionPlan。

### `Object.allocationSize` (`src/core/object.zig:2182`)

- **签名**：`pub fn allocationSize(self: *const Object, rt: *const JSRuntime) usize`。
- **作用**：查询对象供GC使用的body记账尺寸。
- **实现**：按当前class记录计算inline布局，有布局断言窄臂并用object_size，否则固定头加objectTailBytes；最后accountedBodyBytesForPhysical。
- **所有权 / 错误 / 调用**：block可能舍入，inline不含raw leading offset；不是递归对象总内存，也不是所有路线都能直接用它rawFree。

### `Object.createArray` (`src/core/object.zig:2190`)

- **签名**：`pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object`。
- **作用**：按prototype取得初始Array Shape或走通用Array构造。
- **实现**：initialArrayShapeForPrototype命中则createArrayFromShape空entries；否则create(Array)，成功置fast_array=true。
- **所有权 / 错误 / 调用**：创建空dense数组，不复制prototype属性或预分配元素容量；错误传播。

### `Object.createArrayWithOwnPropertyCapacity` (`src/core/object.zig:2199`)

- **签名**：`pub fn createArrayWithOwnPropertyCapacity(rt: *JSRuntime, prototype: ?*Object, capacity: usize) !*Object`。
- **作用**：创建带命名属性预留容量的Array。
- **实现**：createWithOwnPropertyCapacity(Array,prototype,capacity)，成功置fast_array=true。
- **所有权 / 错误 / 调用**：capacity用于own-property槽，不是dense元素capacity或JS length。

## 覆盖核对

- 清单函数数（本文件分到）: 46（`src/core/object.zig` 全文件 873）
- 本文标题覆盖: 46
- 未覆盖: 无
