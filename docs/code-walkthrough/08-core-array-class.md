# 08 — 数组下标与 class 表

覆盖 `array.zig`（纯下标判定 + 字面量构造）与 `class.zig`（进程级 class id + 每 Runtime 定义表）。

## `array.zig` 类型 / 常量

`max_array_index: u32 = 0xffff_fffe`（最大合法数组下标）。`max_array_length = 0xffff_ffff`。

Array 的 dense 值、count、capacity、可见 length 在 `ObjectStorage.array`。zjs 在 array 臂里放 length 标量镜像；qjs 把可见 length 放在普通 shape 属性。突变必须保持 `length >= count`、洞、稀疏回退、不可写 length。

### `isArrayIndexName` (`src/core/array.zig:22`)

- **签名**：`pub fn isArrayIndexName(bytes: []const u8) bool`。
- **作用**：判断字节串是否是合法数组索引十进制形式。
- **实现**：arrayIndexFromName非null即true。
- **所有权 / 错误 / 调用**：不分配，不执行JS ToString或数值转换。

### `arrayIndexFromAtom` (`src/core/array.zig:26`)

- **签名**：`pub fn arrayIndexFromAtom(atoms: anytype, atom_id: atom.Atom) ?u32`。
- **作用**：从atom表示提取数组索引。
- **实现**：tagged integer直接解码并检查<=max_array_index；否则取name，缺失或长度<10返回null，再要求kind=string并解析十进制。
- **所有权 / 错误 / 调用**：短字符串分支依赖atom表已把低范围索引字符串intern成tagged integer的合同；不是任意自定义name/kind提供者都能忽略的优化前提。symbol不作为字符串索引。

### `arrayIndexFromName` (`src/core/array.zig:42`)

- **签名**：`pub fn arrayIndexFromName(bytes: []const u8) ?u32`。
- **作用**：解析0至4294967294的规范十进制数组索引。
- **实现**：空串或多字节前导0返回null；每字节必须ASCII数字，用u64累积且每步超过max_array_index立即返回null。
- **所有权 / 错误 / 调用**：0合法，负号/正号/空格/指数/小数均非法；由于每步限界，下一次乘10前累积量有限，不会因任意长输入而积累到u64溢出。

### `isArrayValue` (`src/core/array.zig:62`)

- **签名**：`pub fn isArrayValue(value: JSValue) !bool`。
- **作用**：不执行trap地沿Proxy target判断Array身份。
- **实现**：非Object返回false；每轮Proxy检查depth>1000后递增，handler为空或target缺失报TypeError，target非Object返回false；遇非Proxy返回isArray。
- **所有权 / 错误 / 调用**：按当前检查顺序最多可穿过1001层Proxy，下一层才StackOverflow；循环Proxy最终也触发该上限。不分配，不解包其他对象或调用代理trap。

### `expectArray` (`src/core/array.zig:82`)

- **签名**：`pub fn expectArray(value: JSValue) !*Object`。
- **作用**：要求输入为直接Array对象并借出指针。
- **实现**：expectObject后检查isArray，否则TypeError。
- **所有权 / 错误 / 调用**：没有ToObject装箱或Proxy解包；Array代理不能因isArrayValue为true而通过本函数。

### `constructLiteralOwnedDenseFromShape` (`src/core/array.zig:121`)

- **签名**：`pub fn constructLiteralOwnedDenseFromShape(rt: *JSRuntime, values: []const JSValue, initial_shape: *shape_mod.Shape) !JSValue`。
- **作用**：从预备Shape构造包含全部输入元素的字面量数组。
- **实现**：value_root_frames_enabled编译期为true时对输入slice constCast后注册.mutable根，再调用Work；否则直接Work。
- **所有权 / 错误 / 调用**：Owned描述调用协议；当前不会逐值RC retain/release，也不清输入内存。输入须在构造期间有效，initial_shape未列入此根帧；单数字元素不会解释为数组长度。

### `constructLiteralOwnedDenseFromShapeWork` (`src/core/array.zig:135`)

- **签名**：`inline fn constructLiteralOwnedDenseFromShapeWork(rt: *JSRuntime, values: []const JSValue, initial_shape: *shape_mod.Shape) !JSValue`。
- **作用**：分配字面量Array并使用trusted dense填充。
- **实现**：Object.createArrayFromInitialShape成功后设置错误destroy，调用initDenseArrayLiteralValuesOwnedTrusted，返回Object值。
- **所有权 / 错误 / 调用**：依赖fresh Array、空dense、可写length及长度范围等trusted前提；不自行注册输出根，根与GC窗口须遵守构造callee协议。输入元素复制表示，没有逐项dup或消费时清零。

### `constructLiteralWithPrototype` (`src/core/array.zig:142`)

- **签名**：`pub fn constructLiteralWithPrototype(rt: *JSRuntime, values: []const JSValue, prototype: ?*Object) !JSValue`。
- **作用**：以给定原型构造借读输入元素的字面量数组。
- **实现**：显式根帧包含输入slice与新数组值；createArray后错误destroy。优先批量初始化；false时预留dense容量，逐项appendDenseArrayLiteralIndex，返回false则defineOwnProperty为w/e/c全true。
- **所有权 / 错误 / 调用**：append返回error直接传播，不进入define回退；当前借值存入也不做RC dup。长度/索引部分转换用intCast，不把超u32输入描述为保证返回InvalidLength。原型未单独列入根帧；失败不返回部分数组。

## `class.zig` 类型

`ClassId = u16`；`invalid_class_id=0`。id 进程全局；定义每 Runtime 独立。`MutationError = error{WrongRuntimeThread}`。

`ids`：object=1 … global_object=68，`init_count=69`。与 `standard_classes` 表、`standardPayloadKind` 一起构成 ObjectStorage 分发矩阵。

`PayloadKind`（u5）：none/ordinary/arguments/object_data/function/bound_function/var_ref/generator/promise/proxy/regexp/iterator/collection/buffer/typed_array/finalization_registry/std_file/disposable_stack/global/realm_record/weak_ref/promise_reaction_record。

`Definition`：注册输入（名字、payload_kind、finalizer/mark、exotic、`native_type`…）。

`Record`：表中一行。`RegistrationState`：generation + construction/live_object/callback pins + unregister_pending。Record 指针会随表增长移动；状态按 id 再取。

`Table.DefinitionPlan`：构造/析构用的不可变标量快照。`Construction`：动态定义的构造 pin。`DeferredPayloadCallbacks`：延迟 finalizer 节点拷贝的函数指针。

标准 id 的 plan 缓存在 standard_plans，已注册项由 registerAtom 填写。standard_classes 当前只列 object=1 至 generator=49；50–68 虽有标准ID和payload回退映射，初始化不会据此自动创建注册记录。标准ID范围、已注册记录与当前对象payload状态必须分别判断。

Payload 是可空 opaque 指针。PayloadVisitor 保存 context 与两个可选 void 回调，分别访问值槽和可空对象槽；真实类型由适配器解释。LegacyFinalizer 和 Call 都是无参void函数指针；PayloadFinalizer 接收 runtime/object/payload槽，PayloadMark 另接 visitor；BindingDataFinalizer 只接不透明data。

Definition/Record 的额外字段包括 binding_identity、binding_data/其finalizer、inline_payload_size/align、legacy与payload回调、call、has_exotic/exotic_methods 和 native_type。Record 把class_name存为atom并保存id，其余注册输入多为浅借用，不能据“不可变记录”推断字符串和opaque目标已复制。inline align默认1，payload_kind默认none。

RegistrationState 从generation0、三种pin计数0和pending=false开始；重新注册的generation按u64环绕递增并跳过0。Construction只存Table指针、ID、DefinitionPlan值和active位，不持跨扩容Record指针。DeferredPayloadCallbacks保存generation、非空finalizer与可空mark。

Table持MemoryAccount/AtomTable借用、owner线程、两个可扩展slice及各69项内联数组、69项标准计划缓存。init使用独立数组，initInPlace使用指向自身内联数组的slice，后者要求地址稳定。定义pin保护注册记录的生命周期，不等同于GC pin。

### `lockDynamicClassIds` (`src/core/class.zig:31`)

- **签名**：`fn lockDynamicClassIds() void`。
- **作用**：取得进程级动态class ID自旋锁。
- **实现**：循环atomic swap(true,acquire)，失败执行spinLoopHint。
- **所有权 / 错误 / 调用**：非可重入，不保证公平性，不锁定单个runtime定义表。

### `unlockDynamicClassIds` (`src/core/class.zig:35`)

- **签名**：`fn unlockDynamicClassIds() void`。
- **作用**：释放动态ID分配锁。
- **实现**：atomic store(false,release)。
- **所有权 / 错误 / 调用**：调用者须持锁；没有持有者验证或唤醒队列。

### `allocateDynamicClassIdLocked` (`src/core/class.zig:39`)

- **签名**：`fn allocateDynamicClassIdLocked() error{ClassIdExhausted}!ClassId`。
- **作用**：在已持锁前提下分配新动态ID。
- **实现**：u32计数器从69开始；超过u16最大值报ClassIdExhausted，否则转u16后递增。
- **所有权 / 错误 / 调用**：65535可用，下一次失败而不回绕；不注册定义、不回收或复用ID。

### `allocateDynamicClassId` (`src/core/class.zig:46`)

- **签名**：`pub fn allocateDynamicClassId() error{ClassIdExhausted}!ClassId`。
- **作用**：加锁分配独立动态class ID。
- **实现**：lock后defer unlock，调用Locked版本。
- **所有权 / 错误 / 调用**：错误时也解锁；进程级身份不等于任意runtime已注册。

### `ClassIdSlot.getOrAllocate` (`src/core/class.zig:57`)

- **签名**：`pub fn getOrAllocate(self: *ClassIdSlot) error{ClassIdExhausted}!ClassId`。
- **作用**：为调用者维护稳定的class身份。
- **实现**：持全局锁；slot.value为0才分配并保存，否则原样返回。
- **所有权 / 错误 / 调用**：分配失败slot保持0；已有非0值不验证来源或runtime注册状态，直接手改value须遵守并发合同。

### `isNumericTypedArrayClass` (`src/core/class.zig:175`)

- **签名**：`pub inline fn isNumericTypedArrayClass(id: ClassId) bool`。
- **作用**：识别Number元素类型的TypedArray class。
- **实现**：仅uint8c/int8/uint8/int16/uint16/int32/uint32/float16/float32/float64返回true。
- **所有权 / 错误 / 调用**：排除BigInt数组与DataView；只按ID判别，不检查对象payload或buffer有效性。

### `isBytecodeFunctionClass` (`src/core/class.zig:192`)

- **签名**：`pub inline fn isBytecodeFunctionClass(id: ClassId) bool`。
- **作用**：识别使用bytecode臂的四类函数。
- **实现**：bytecode_function/generator_function/async_function/async_generator_function为true。
- **所有权 / 错误 / 调用**：不覆盖native/bound函数，不检查实际对象是否可调用或已有FB。

### `isAsyncFunctionResumeClass` (`src/core/class.zig:204`)

- **签名**：`pub inline fn isAsyncFunctionResumeClass(id: ClassId) bool`。
- **作用**：识别内部async continuation的resolve/reject类。
- **实现**：id为async_function_resolve或async_function_reject。
- **所有权 / 错误 / 调用**：不是所有Promise resolving函数或async generator方法的统称。

### `PayloadVisitor.value` (`src/core/class.zig:215`)

- **签名**：`pub fn value(self: *PayloadVisitor, value_ptr: *anyopaque) void`。
- **作用**：转发不透明值槽给可选回调。
- **实现**：visit_value缺失返回，存在则调用(context,value_ptr)。
- **所有权 / 错误 / 调用**：void接口不传播error，不验证指针类型或自行标记；外层适配器负责真实类型及错误记录。

### `PayloadVisitor.object` (`src/core/class.zig:220`)

- **签名**：`pub fn object(self: *PayloadVisitor, object_ptr: *anyopaque) void`。
- **作用**：转发可空强对象槽给可选回调。
- **实现**：visit_object缺失返回，存在则调用(context,object_ptr)。
- **所有权 / 错误 / 调用**：参数是槽地址的不透明表示，不是直接Object指针；本体不检查槽内容或建立根。

### `Record.isRegistered` (`src/core/class.zig:270`)

- **签名**：`pub fn isRegistered(self: Record) bool`。
- **作用**：按record身份判断是否已占用。
- **实现**：id!=invalid_class_id(0)。
- **所有权 / 错误 / 调用**：不检查unregister_pending、pin或callbacks是否可用。

### `Record.finalizeBindingData` (`src/core/class.zig:274`)

- **签名**：`pub fn finalizeBindingData(self: Record) void`。
- **作用**：调用存在的binding data销毁回调。
- **实现**：data为空或finalizer为空均返回，否则finalizer(data)。
- **所有权 / 错误 / 调用**：self按值传入，不清原record，不防重复或重入；注销顺序/回调期间保护由Table保证。

### `fillDefaultRecords` (`src/core/class.zig:285`)

- **签名**：`fn fillDefaultRecords(records: []Record) void`。
- **作用**：用零填充和align默认值初始化record数组。
- **实现**：memset std.mem.zeroes(Record)，再逐项inline_payload_align=1。
- **所有权 / 错误 / 调用**：不销毁被覆盖的已有资源；只用于空/新存储，效果对应Record默认字段。

### `RegistrationState.isPinned` (`src/core/class.zig:302`)

- **签名**：`fn isPinned(self: RegistrationState) bool`。
- **作用**：检查任一class生命周期保护计数是否非零。
- **实现**：construction/live_object/callback三者OR。
- **所有权 / 错误 / 调用**：不看generation/unregister_pending；这些pin保护定义，不是GC对象根。

### `Table.Construction.publishObject` (`src/core/class.zig:328`)

- **签名**：`pub fn publishObject(self: *Construction) void`。
- **作用**：把动态定义的构造保护转交给已初始化对象。
- **实现**：经assertOwnerThread检查线程（关闭runtime safety时为空操作）；inactive返回。按class_id重新取state/record，断言generation和id匹配、构造计数非0，减construction并增live_object，清active。
- **所有权 / 错误 / 调用**：不登记GC对象、不初始化payload，也不在此完成pending unregister；记录指针可能移动所以不跨分配保留。

### `Table.Construction.abort` (`src/core/class.zig:347`)

- **签名**：`pub fn abort(self: *Construction) void`。
- **作用**：撤销尚未发布的动态构造保护。
- **实现**：经assertOwnerThread检查线程（关闭runtime safety时为空操作）；inactive返回，核对generation/count，减construction并清active，然后completePendingUnregister。
- **所有权 / 错误 / 调用**：应在构造资源清理后执行，最后保护解除可能完成注销并触发绑定清理；已publish后abort无重复减计数。

### `Table.init` (`src/core/class.zig:385`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) !Table`。
- **作用**：按值返回初始化后的class表。
- **实现**：记录当前线程，填standard plan回退值，ensureCapacity(69)创建记录/状态存储，再注册标准类；失败deinit。
- **所有权 / 错误 / 调用**：此入口走独立分配，区别于initInPlace的自引用内联slice；不分配进程级动态ID。

### `Table.initInPlace` (`src/core/class.zig:400`)

- **签名**：`pub fn initInPlace(self: *Table, account: *memory.MemoryAccount, atoms: *atom.AtomTable) !void`。
- **作用**：在稳定地址初始化使用内联数组的class表。
- **实现**：覆盖self默认字段并记录线程，填plans，records/states指向各自69项内联数组，初始化记录/状态后注册标准类，失败deinit。
- **所有权 / 错误 / 调用**：不能把完成后的Table任意按值移动而保留原内联指针；不先销毁已有self，调用者须提供未初始化/已清理目标。

### `Table.registerStandardClasses` (`src/core/class.zig:417`)

- **签名**：`fn registerStandardClasses(self: *Table) !void`。
- **作用**：登记standard_classes列表中的预定义项。
- **实现**：每项用其预定义name_atom和standardPayloadKind调用registerAtom，Definition其他字段默认。
- **所有权 / 错误 / 调用**：不等于登记所有id<69；未列出的标准ID仍保留plan回退值，出错停止，调用者负责整体清理。

### `Table.usingInlineRecords` (`src/core/class.zig:426`)

- **签名**：`fn usingInlineRecords(self: *const Table) bool`。
- **作用**：判断records起点是否为本对象内联数组。
- **实现**：比较两个ptr相等。
- **所有权 / 错误 / 调用**：不比较长度或校验所有权；用于选择重置还是free。

### `Table.usingInlineRegistrationStates` (`src/core/class.zig:430`)

- **签名**：`fn usingInlineRegistrationStates(self: *const Table) bool`。
- **作用**：判断状态slice是否采用本对象内联数组。
- **实现**：比较registration_states.ptr与内联数组ptr。
- **所有权 / 错误 / 调用**：依赖Table地址稳定，不验证长度或内容。

### `Table.isOwnerThread` (`src/core/class.zig:434`)

- **签名**：`pub fn isOwnerThread(self: *const Table) bool`。
- **作用**：检查当前线程是否等于创建线程。
- **实现**：owner_thread_id==Thread.getCurrentId。
- **所有权 / 错误 / 调用**：不加锁、不迁移线程归属。

### `Table.requireOwnerThread` (`src/core/class.zig:438`)

- **签名**：`pub fn requireOwnerThread(self: *const Table) MutationError!void`。
- **作用**：提供可返回错误的线程检查。
- **实现**：不匹配则WrongRuntimeThread，否则返回成功。
- **所有权 / 错误 / 调用**：不受assertOwnerThread的runtime_safety编译期开关豁免；不改表状态。

### `Table.assertOwnerThread` (`src/core/class.zig:449`)

- **签名**：`pub inline fn assertOwnerThread(self: *const Table) void`。
- **作用**：按构建安全模式启用线程断言。
- **实现**：runtime_safety为false时编译为空，否则调用Checked版本。
- **所有权 / 错误 / 调用**：不是所有发布配置都强制检测的线程安全保障；调用协议始终要求owner线程。

### `Table.assertOwnerThreadChecked` (`src/core/class.zig:454`)

- **签名**：`noinline fn assertOwnerThreadChecked(self: *const Table) void`。
- **作用**：在错误线程直接panic。
- **实现**：isOwnerThread为false时panic指定错误消息。
- **所有权 / 错误 / 调用**：不返回MutationError；供带安全检查的包装层调用。

### `Table.deinit` (`src/core/class.zig:458`)

- **签名**：`pub fn deinit(self: *Table) void`。
- **作用**：摘除表slice、清绑定数据并释放或重置存储。
- **实现**：保存旧records/states和是否inline，先清self两个slice，再对注册记录finalizeBindingData；随后断言所有state无pin，inline数组重置，非inline非空数组free。
- **所有权 / 错误 / 调用**：pin断言在回调之后，不是先验证再析构；不逐atom释放、不重置standard_plans/线程/依赖指针。完整runtime销毁顺序必须先解除构造/对象/回调保护。

### `Table.register` (`src/core/class.zig:484`)

- **签名**：`pub fn register(self: *Table, id: ClassId, def: Definition) !void`。
- **作用**：检查线程后登记指定ID的定义。
- **实现**：requireOwnerThread，拒绝id0，先ensureCapacity(id+1)，再intern class_name，最后registerAtom。
- **所有权 / 错误 / 调用**：预扩表避免name atom在后续扩表分配窗口失根；失败可能保留已扩容量或intern副作用，不是整调用回滚，也不分配ID。

### `Table.unregisterDynamic` (`src/core/class.zig:497`)

- **签名**：`pub fn unregisterDynamic(self: *Table, id: ClassId) void`。
- **作用**：在调用合同要求的线程请求注销动态定义。
- **实现**：assertOwnerThread后调用unregisterDynamicOwned。
- **所有权 / 错误 / 调用**：assert在关闭runtime safety时不执行；此void入口不报告WrongRuntimeThread，保护计数可使注销延后。

### `Table.tryUnregisterDynamic` (`src/core/class.zig:504`)

- **签名**：`pub fn tryUnregisterDynamic(self: *Table, id: ClassId) MutationError!void`。
- **作用**：通过可恢复线程检查请求注销。
- **实现**：requireOwnerThread成功后调用Owned版本。
- **所有权 / 错误 / 调用**：线程错误发生在设置pending或改变记录之前；成功返回不保证定义已立即移除。

### `Table.unregisterDynamicOwned` (`src/core/class.zig:509`)

- **签名**：`fn unregisterDynamicOwned(self: *Table, id: ClassId) void`。
- **作用**：标记合法动态定义待注销并尝试完成。
- **实现**：标准ID、越界或未注册直接返回；否则state.pending=true，再completePendingUnregister。
- **所有权 / 错误 / 调用**：已有pin时保留记录等待释放；ID本身不归还进程分配器，pending后禁止新动态构造。

### `Table.beginConstruction` (`src/core/class.zig:519`)

- **签名**：`pub fn beginConstruction(self: *Table, id: ClassId) error{InvalidClassId}!Construction`。
- **作用**：取得构造标量快照并保护动态定义。
- **实现**：标准ID委托beginStandardConstruction；动态ID检查线程assert、范围/注册/pending，非法报InvalidClassId；有效时construction_pins+1，返回按generation复制的plan与active标记。
- **所有权 / 错误 / 调用**：不分配Object或建立GC根；pending之前已取得的构造可完成，之后新请求被拒绝。不持有跨分配的Record指针。

### `Table.beginStandardConstruction` (`src/core/class.zig:544`)

- **签名**：`pub fn beginStandardConstruction(self: *Table, id: ClassId) Construction`。
- **作用**：创建不计pin的标准ID构造视图。
- **实现**：线程assert后返回table/id、standardPlan副本和active=false。
- **所有权 / 错误 / 调用**：不检查记录已注册，标准计划允许回退；参数必须小于69，id0也不会在此单独拒绝。

### `Table.standardPlan` (`src/core/class.zig:557`)

- **签名**：`pub fn standardPlan(self: *const Table, id: ClassId) DefinitionPlan`。
- **作用**：按值读取标准类计划缓存。
- **实现**：断言id<69，直接返回standard_plans[id]。
- **所有权 / 错误 / 调用**：不检查注册状态或线程，也不重新读取Record；未注册标准ID使用初始化的fallback。

### `Table.destructionPlan` (`src/core/class.zig:564`)

- **签名**：`pub fn destructionPlan(self: *const Table, id: ClassId) ?DefinitionPlan`。
- **作用**：读取析构所需定义标量。
- **实现**：标准ID直接返回缓存；动态ID越界或live_object_pins为0返回null，否则从现记录和generation生成plan。
- **所有权 / 错误 / 调用**：即使pending也可取得动态析构计划；不增加保护计数，不验证某个特定对象的generation。

### `Table.releaseObjectDefinition` (`src/core/class.zig:574`)

- **签名**：`pub fn releaseObjectDefinition(self: *Table, id: ClassId, generation: u64) void`。
- **作用**：归还一个动态对象对定义的生命周期保护。
- **实现**：标准ID直接返回；动态分支线程assert、校验state范围/generation/计数，live_object_pins减1，再尝试完成注销。
- **所有权 / 错误 / 调用**：调用者须在对象分配不再需要定义后调用；不销毁Object，不涉及已退役的weak husk保留流程。最后一项保护解除可能触发绑定清理。

### `Table.pinDeferredPayloadCallbacks` (`src/core/class.zig:592`)

- **签名**：`pub fn pinDeferredPayloadCallbacks(self: *Table, id: ClassId, generation: u64) ?DeferredPayloadCallbacks`。
- **作用**：复制延迟payload finalizer/mark并保护动态定义。
- **实现**：线程assert；无record或无payload_finalizer返回null。动态ID还要求generation匹配且live_object_pins非0，再增callback_pins；返回传入generation及函数指针。
- **所有权 / 错误 / 调用**：标准ID不增加callback计数，也不核对传入generation；不检查pending阻止已有对象的清理，不实际排队或调用回调。

### `Table.releaseDeferredPayloadCallbacks` (`src/core/class.zig:608`)

- **签名**：`pub fn releaseDeferredPayloadCallbacks(self: *Table, id: ClassId, generation: u64) void`。
- **作用**：归还延迟回调的定义保护。
- **实现**：先线程assert；标准ID返回。动态分支验证范围/generation/非零计数，减callback_pins并尝试完成注销。
- **所有权 / 错误 / 调用**：不执行finalizer，必须与成功取得的动态pin配对；不能因返回void把代次检查视作运行时错误恢复。

### `Table.unregisterPending` (`src/core/class.zig:619`)

- **签名**：`pub fn unregisterPending(self: *const Table, id: ClassId) bool`。
- **作用**：读取指定ID的待注销标志。
- **实现**：超出state slice返回false，否则读取pending。
- **所有权 / 错误 / 调用**：不要求当前已注册，不触发注销。

### `Table.isRegistered` (`src/core/class.zig:624`)

- **签名**：`pub fn isRegistered(self: Table, id: ClassId) bool`。
- **作用**：按ID检查记录占用。
- **实现**：超出records返回false，否则Record.isRegistered。
- **所有权 / 错误 / 调用**：pending但尚未移除的定义仍返回true；不代表允许新构造。

### `Table.className` (`src/core/class.zig:629`)

- **签名**：`pub fn className(self: *Table, id: ClassId) ?atom.Atom`。
- **作用**：借用已注册定义的名称atom。
- **实现**：线程assert后检查isRegistered，未注册null，否则返回class_name。
- **所有权 / 错误 / 调用**：包含pending记录；不创建atom根或复制字符串，线程assert受runtime safety开关控制。

### `Table.findByName` (`src/core/class.zig:635`)

- **签名**：`pub fn findByName(self: *const Table, name: []const u8) ?ClassId`。
- **作用**：按名称字节寻找首个已注册定义。
- **实现**：按records顺序遍历，跳过未注册或无atom名称项，std.mem.eql命中返回rec.id。
- **所有权 / 错误 / 调用**：不同ID可共用名称，返回首次命中；不排除pending、不验证唯一性或做线程检查。

### `Table.findByIdentity` (`src/core/class.zig:644`)

- **签名**：`pub fn findByIdentity(self: *const Table, identity: []const u8) ?ClassId`。
- **作用**：按binding_identity字节寻找首个已注册定义。
- **实现**：按records顺序跳过未注册/无identity项，字节相等即返回ID。
- **所有权 / 错误 / 调用**：不比较指针地址，不排除pending；不建立保护计数或独立拷贝。

### `Table.record` (`src/core/class.zig:653`)

- **签名**：`pub fn record(self: *const Table, id: ClassId) ?Record`。
- **作用**：取得已注册Record的浅拷贝。
- **实现**：越界或未注册null，否则按值返回。
- **所有权 / 错误 / 调用**：拷贝中slice/opaque/callback仍借用原资源，不能靠浅拷跨注销保持资源存活；pending仍可读取。

### `Table.recordPtr` (`src/core/class.zig:670`)

- **签名**：`pub fn recordPtr(self: *const Table, id: ClassId) ?*const Record`。
- **作用**：借用已注册Record的表内地址。
- **实现**：越界或未注册null，否则返回只读指针。
- **所有权 / 错误 / 调用**：表扩容可移动所有记录，注销可清内容；只用于无分配/无GC/无回调窗口，跨窗口应采用plan与generation/pin。

### `Table.runFinalizer` (`src/core/class.zig:677`)

- **签名**：`pub fn runFinalizer(self: *Table, id: ClassId) bool`。
- **作用**：运行存在的legacy无参finalizer。
- **实现**：线程assert，pinCallback取得generation并defer release，重新取record/finalizer，无则false，调用后true。
- **所有权 / 错误 / 调用**：回调期间动态定义保持注册，缺回调也会释放临时pin；不执行payload finalizer或注销对象。

### `Table.runPayloadFinalizerForTest` (`src/core/class.zig:686`)

- **签名**：`pub fn runPayloadFinalizerForTest( self: *Table, id: ClassId, runtime: *anyopaque, object: *anyopaque, payload: *Payload, ) bool`。
- **作用**：测试里直接跑 payload_finalizer。
- **实现**：先线程 assert；非 test 构建走 `@compileError`。pinCallback 取得 generation 并 defer releaseCallback；再经 recordPtr 取 payload_finalizer，缺 record 或缺回调返回 false，否则调用 (runtime,object,payload) 后返回 true。
- **所有权 / 错误 / 调用**：测试专用（非 test 构建是 `@compileError`）。所有权上它**不释放 payload**，只把 `runtime`/`object`/`payload` 三个裸指针原样转交给注册的 `payload_finalizer`，三者的存活由调用方保证；`pinCallback`/`releaseCallback` 成对护住 class 记录，使 finalizer 运行期间该 class 不被注销。返回 bool 而非 error：class 不存在、未注册 finalizer、pin 失败都返回 false，无法区分。与生产版 `runPayloadFinalizer`（`src/core/class.zig:702`）的差别是跳过 generation 校验。调用方 `src/tests/core.zig:4022`、`:4025`。

### `Table.runPayloadFinalizer` (`src/core/class.zig:702`)

- **签名**：`pub fn runPayloadFinalizer( self: *Table, id: ClassId, expected_generation: u64, runtime: *anyopaque, object: *anyopaque, payload: *Payload, ) bool`。
- **作用**：在代次匹配时运行payload finalizer。
- **实现**：线程assert，取得callback pin并defer释放；动态ID generation不匹配false，缺record/finalizer false，否则调用(runtime,object,payload)并true。
- **所有权 / 错误 / 调用**：标准ID忽略expected_generation；bool表示是否调用，不是回调返回结果。payload是可变槽地址，具体清理及置空由回调负责。

### `Table.markPayload` (`src/core/class.zig:719`)

- **签名**：`pub fn markPayload( self: *Table, id: ClassId, runtime: *anyopaque, object: *anyopaque, payload: *Payload, visitor: *PayloadVisitor, ) bool`。
- **作用**：运行存在的payload mark回调。
- **实现**：先读record.payload_mark，无则false；有才线程assert、取得callback pin、调用保存的mark并defer释放，返回true。
- **所有权 / 错误 / 调用**：无回调快速返回不检查owner线程，支持mutator停止时并行读取；真正回调仍有owner线程合同。visitor错误不通过此bool接口直接返回。

### `Table.registerAtom` (`src/core/class.zig:741`)

- **签名**：`fn registerAtom(self: *Table, id: ClassId, name_atom: atom.Atom, def: Definition) !void`。
- **作用**：提交指定ID的不可变定义并增加代次。
- **实现**：检查线程/id、ensureCapacity，重复记录报DuplicateClass；断言无pin和pending，generation环绕+1并跳过0。name经noteHolderStore，其他Definition字段浅拷，has_exotic合并布尔和指针；标准ID同时更新缓存plan。
- **所有权 / 错误 / 调用**：不深拷binding_identity/data/native_type，不校验回调与payload布局组合；generation理论上可环绕复用，不是永不重复的进程ID。记录安装后无fallible步骤。

### `Table.ensureCapacity` (`src/core/class.zig:775`)

- **签名**：`fn ensureCapacity(self: *Table, needed: usize) !void`。
- **作用**：同时扩展记录表与生命周期状态表。
- **实现**：线程检查，足够即返回；目标为初始69或1.5倍并至少needed。依次分配两数组，默认初始化并复制旧内容，安装两slice，最后重置旧inline或free旧独立数组。
- **所有权 / 错误 / 调用**：任一分配失败不安装新slice，已取得新数组由errdefer归还；成功后旧Record/State裸指针失效。不执行binding finalizer或改变注册代次。

### `Table.fillStandardPlanFallbacks` (`src/core/class.zig:807`)

- **签名**：`fn fillStandardPlanFallbacks(plans: *[ids.init_count]DefinitionPlan) void`。
- **作用**：初始化所有标准ID的默认构造计划。
- **实现**：逐索引写仅payload_kind=standardPayloadKind(id)的默认DefinitionPlan。
- **所有权 / 错误 / 调用**：generation0、align1，其他元数据默认；并不把ID登记为registered。

### `Table.definitionPlan` (`src/core/class.zig:813`)

- **签名**：`fn definitionPlan(definition_view: ?*const Record, id: ClassId, generation: u64) DefinitionPlan`。
- **作用**：按值摘取构造/析构所需标量。
- **实现**：有record时取指定generation、payload_kind、inline尺寸/对齐、finalizer是否非空、exotic布尔或指针；无record时仅generation和standardPayloadKind回退。
- **所有权 / 错误 / 调用**：不复制回调指针或binding数据，不验证id与record一致，不自己取得pin。

### `Table.pinCallback` (`src/core/class.zig:830`)

- **签名**：`fn pinCallback(self: *Table, id: ClassId) ?u64`。
- **作用**：临时保护已注册定义并返回代次。
- **实现**：record不存在null；标准ID只返回generation，动态ID先callback_pins+1。
- **所有权 / 错误 / 调用**：不排除pending或要求live_object_pin，不建立GC根；必须与releaseCallback配对。

### `Table.releaseCallback` (`src/core/class.zig:838`)

- **签名**：`fn releaseCallback(self: *Table, id: ClassId, generation: u64) void`。
- **作用**：释放同步回调保护并尝试完成注销。
- **实现**：标准ID无操作；动态ID断言generation/非零count，减callback_pins，再completePendingUnregister。
- **所有权 / 错误 / 调用**：无独立范围/线程检查，依赖已成功pin的内部调用合同。

### `Table.completePendingUnregister` (`src/core/class.zig:847`)

- **签名**：`fn completePendingUnregister(self: *Table, id: ClassId) void`。
- **作用**：在全部pin解除后移除动态定义。
- **实现**：标准/越界返回；非pending或仍pinned返回。保存旧record，断言registered，先清records[id]和pending，再调用旧定义finalizeBindingData。
- **所有权 / 错误 / 调用**：先发布空槽允许回调重入注册，不在回调后再覆盖新记录；保留state.generation供下次递增，不归还动态ID，也不逐atom释放。

### `standardPayloadKind` (`src/core/class.zig:918`)

- **签名**：`pub fn standardPayloadKind(id: ClassId) PayloadKind`。
- **作用**：给标准class ID提供payload种类默认映射。
- **实现**：按switch区分ordinary/global/resource、wrapper object_data、function/bound、iterator、buffer/typed_array、collection、generator、proxy、promise、weak/FR；array/module_ns/async resolve/reject及未知ID为none。
- **所有权 / 错误 / 调用**：arguments/mapped_arguments默认ordinary，promise resolve/reject默认为promise；映射不证明实际payload已分配或该ID已注册，动态定义可指定其他kind。

## 覆盖核对

- 清单函数数: 65（`src/core/array.zig` 9 + `src/core/class.zig` 56）
- 本文标题覆盖: 65
- 未覆盖: 无
