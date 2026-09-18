# 10 — JSContext / Realm

`JSContext` 是 Runtime 拥有的一个 GC 节点，表示一个 ECMAScript realm：全局对象、模块registry、词法环境、class prototype和初始shape；挂起异常位于所属runtime，由同runtime的realm共享。QuickJS 对照 `JSContext` realm 字段（quickjs.c:500-557）。裸 `*JSContext` 是借用；跨 job/回调的拥有句柄是 `RealmRef`（`JS_DupContext` / `JS_FreeContext` 的 tracing 对应物——不再是 rc，只是一条被描的边）。

公开拼写保留 `JSContext`；`RealmContext` 是同一类型的别名，不是包装。

core 拥有本类型；exec/runtime/binding 可消费，context 不得反向 import 那些层。eval/属性/调用的真正实现在 binding + exec；本文件是 realm 状态与宿主钩子。

---

## 文件级类型

`RealmValueSlot`：realm 缓存的内建值槽（throw TypeError 固有函数、各 prototype、async/generator 函数、iterator helper、regexp/promise 构造器、callsite prototype 等），`count` 为上限。

`BacktraceFrame`：物化栈帧。`function_name`/`filename` 是 atom；`pc` 或 `pc_source`（指向活 PC 的指针，`currentPc` 读 `*pc_source -| 1`）；可选 `location_resolver`；`function_value` 供惰性解析显示名。

`ActiveBacktraceFrame`：栈上活帧组节点。`resolver(data, index)` 枚举一整次 VM 调用的 inline Machine Entry 链（最内先行）再加 L0 帧，对齐 qjs 单条 `prev_frame` 走访（quickjs.c:7571）。

`ActiveBacktraceSnapshot`：resolver 返回的一帧快照，含 `backtrace_barrier`。pc默认0，location_data/resolver默认null，function_value默认undefined，barrier/is_native默认false。快照不含pc_source。ActiveBacktraceFrame.previous默认null，data与resolver由调用方提供；这些结构本身不拥有opaque数据。

`BacktraceLocation` / `BacktraceLocationResolver`：按 PC 解析行列。

`DynamicImportError`：`RuntimeError` ∪ `AccessDenied`/`PermissionDenied`/`Unexpected`。宿主 I/O 在 producer 缝转换成这几个。

`DynamicImportCallback`：`(userdata, ctx, output, global, referrer_path, specifier) DynamicImportError!JSValue`。Runtime 级 loader 在调用时注入当前 Realm。

`ContextOptions`（别名Options）：stack_size默认null，track_unhandled_rejections默认false；本声明不实施栈限制或拒绝跟踪。

`ContextEvalTiming`（别名EvalTiming）：八个u64字段默认0。parse_ns保留历史名字，记录完整编译边界，与compile_ns累计同一增量，不应两者相加当总时间；frontend/finalize细分编译。root_function_publish_ns、first_execute_ns、vm_run_ns和promise_jobs_ns描述不同边界，first_execute包含普通script/eval的root发布与VM执行，不包含随后微任务drain。结构本身不计时或清零，消费端按路径累加。

`EvalMode`：`script` / `module` / `eval_direct` / `eval_indirect`。

`EvalSourceKind`：`auto` / `javascript` / `typescript`。

`ContextEvalOptions`（别名EvalOptions）：mode默认script，filename为<eval>，source_kind为auto，output/timing为null；parse_strict/runtime_strict为false，return_completion为true，discard_script_result为false。选项定义不执行语法判断或求值，消费行为在exec/binding。

`DataPropertyOptions`：writable/enumerable/configurable均默认true。PropertyAccessOptions的output/realm_global默认null；FunctionCallOptions另有可选this_value默认null。ErrorOptions的realm_global默认null、capture_stack默认true；ScriptEvalOptions的output/realm_global默认null、filename默认<evalScript>。PropertyDescriptor直接别名Descriptor，没有新增包装。

`SharedArrayBufferRef`：store为可选opaque指针，max_byte_length为可选usize，均默认null。底层SharedBufferStore使用独立宿主引用计数；此ref只携带最大长度元数据，不在retain/release中校验或更改缓冲区大小。

`SignalDisposition`：`default` / `ignore`。

`HostEventLoop`：`ptr` + `VTable`。把 CLI/嵌入循环接到 realm，**不是** `jobs.Queue`。vtable 含 traceRoots、exit code、timer、rw handler、signal handler。

`NativeErrorKind`为u8枚举：error_、eval_error、range_error、reference_error、syntax_error、type_error、uri_error、internal_error、aggregate_error、suppressed_error；count为哨兵，native_error_kind_count=10。原型槽与全局上可变Error构造器绑定独立。

`RealmPublicationState`：`constructing` / `live` / `finalizing`。

`UnhandledRejectionEntry`：promise与reason均为JSValue，默认undefined；promise可表示生产者未提供对象。对齐 CLI `JSRejectedPromiseEntry`（quickjs-libc.c:147-151）。

`JSContext`：2176 字节、16 对齐、`header` offset 0、`runtime` 1472、`modules` 1424、`publication_state` 2160、`global` 288。尾洞 2168 放 O(1) trace-list predecessor。`gc_kind_tag = realm_context`。

关键字段：`runtime_prev/next`（live 枚举，非所有权）、`construction_prev/next`、`host_api_release_consumed`、`modules`、`unhandled_rejections`、class/native-error prototypes（先 inline 69 槽）、cached prototypes/values、五個初始 shape、`interrupt_counter`（qjs `JSContext.interrupt_counter`，默认 0 使第一次 poll 走慢路径并重置到 10000）、`global`/`lexicals`、`eval_function`、`host_event_loop`。

原型内嵌数组与native error数组默认JS null，cached_values的可选槽默认null；五个shape、global/lexicals、host loop、regexp静态状态及OOM预分配值默认空。random_state字段默认固定种子，但initConstructing会改用newRealmRandomSeed；eval_function默认JS null。拒绝数组默认空、容量0，preserve_uncaught_exception默认false。构造完成标志与宿主引用消费标志均默认false，不能从publication_state单独推导它们。

---

## `SharedArrayBufferRef`

### `SharedArrayBufferRef.retain` (`src/core/context.zig:228`)

- **签名**：`pub fn retain(self: SharedArrayBufferRef) SharedArrayBufferRef`。
- **作用**：复制引用并增加底层共享存储的宿主引用数。
- **实现**：sharedStore为空返回全默认空ref；否则调用store.retain后返回self位拷贝，保留max_byte_length。
- **所有权 / 错误 / 调用**：底层使用原子引用计数，和JS对象tracing不同；不会创建JS包装对象。普通结构位拷贝不会自动retain，新引用需配对release。

### `SharedArrayBufferRef.release` (`src/core/context.zig:234`)

- **签名**：`pub fn release(self: *SharedArrayBufferRef) void`。
- **作用**：释放本引用持有的共享存储份额。
- **实现**：若store为空直接返回；否则先将store和max_byte_length置null，再store.release。
- **所有权 / 错误 / 调用**：底层最后一次release会释放字节或调用external_deinit并销毁store；先清字段避免同一引用重入重复释放。store原本为空时不会清残留max_byte_length，不能据此当作通用重置。

### `SharedArrayBufferRef.sharedStore` (`src/core/context.zig:241`)

- **签名**：`pub fn sharedStore(self: SharedArrayBufferRef) ?*object_mod.SharedBufferStore`。
- **作用**：借用opaque指针对应的SharedBufferStore。
- **实现**：store为空返回null，否则alignCast并ptrCast。
- **所有权 / 错误 / 调用**：只有对齐/类型转换，没有运行时品牌或存活校验；不增加引用数，不允许返回指针活过最后一个有效store引用。

## `HostEventLoop` vtable 转发

这些方法只把调用转到宿主循环；ptr和vtable不被拥有，没有析构方法、线程同步或默认实现。运行/登记接口传播宿主anyerror，traceRoots使用RootTraceError，其余void/可选值/ID接口不返回错误。core不在这些包装中实现定时器、fd轮询或信号处理。

### `HostEventLoop.traceRoots` (`src/core/context.zig:272`)

- **签名**：`pub fn traceRoots(self: HostEventLoop, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：向宿主请求枚举其持有的根。
- **实现**：调用vtable.traceRoots(ptr,visitor)，传播RootTraceError。
- **所有权 / 错误 / 调用**：不是anyerror接口；core不自行扫描timer或其他表，宿主必须正确实现根枚举。ptr/vtable为借用且须有效。

### `HostEventLoop.setExitCode` (`src/core/context.zig:276`)

- **签名**：`pub fn setExitCode(self: HostEventLoop, code: u8) void`。
- **作用**：转发退出码设置请求。
- **实现**：调用vtable.setExitCode(ptr,code)。
- **所有权 / 错误 / 调用**：本包装不退出进程、不保存额外副本，无错误返回通道，实际行为由宿主实现。

### `HostEventLoop.exitCode` (`src/core/context.zig:280`)

- **签名**：`pub fn exitCode(self: HostEventLoop) ?u8`。
- **作用**：查询宿主保存的可选退出码。
- **实现**：返回vtable.exitCode(ptr)。
- **所有权 / 错误 / 调用**：null含义由宿主状态决定，本包装不设置或清除状态，无错误返回。

### `HostEventLoop.nextTimerId` (`src/core/context.zig:284`)

- **签名**：`pub fn nextTimerId(self: HostEventLoop) i64`。
- **作用**：请求宿主返回下一个timer ID。
- **实现**：返回vtable.nextTimerId(ptr)的i64。
- **所有权 / 错误 / 调用**：包装不验证唯一性、符号或溢出，也不登记timer；ID策略由宿主实现，无错误返回。

### `HostEventLoop.enqueueTimer` (`src/core/context.zig:288`)

- **签名**：`pub fn enqueueTimer(self: HostEventLoop, ctx: *JSContext, id: i64, callback: JSValue, delay_ms: u64, repeats: bool) !void`。
- **作用**：转发定时器登记参数。
- **实现**：将ptr、ctx、id、callback、delay_ms和repeats原样传给vtable.enqueueTimer。
- **所有权 / 错误 / 调用**：宿主anyerror直接传播，不自动回滚或retain；成功保存的JS值需纳入宿主根枚举，失败时消费契约由具体实现决定。

### `HostEventLoop.clearTimer` (`src/core/context.zig:292`)

- **签名**：`pub fn clearTimer(self: HostEventLoop, ctx: *JSContext, id: i64) void`。
- **作用**：转发取消指定timer的请求。
- **实现**：调用vtable.clearTimer(ptr,ctx,id)。
- **所有权 / 错误 / 调用**：不自行查表，不保证宿主对未知ID的处理策略；无错误返回。

### `HostEventLoop.runNextTimer` (`src/core/context.zig:296`)

- **签名**：`pub fn runNextTimer(self: HostEventLoop, ctx: *JSContext, output: ?*std.Io.Writer, global: *Object) !bool`。
- **作用**：转发运行下一timer的请求。
- **实现**：原样返回vtable.runNextTimer(ptr,ctx,output,global)的bool或错误。
- **所有权 / 错误 / 调用**：到期选择、等待及bool具体含义由宿主实现；不能仅凭包装宣称成功执行了一个JS回调。不会自动drain core job队列。

### `HostEventLoop.setRwHandler` (`src/core/context.zig:300`)

- **签名**：`pub fn setRwHandler(self: HostEventLoop, ctx: *JSContext, fd: i32, write_handler: bool, callback: JSValue) !void`。
- **作用**：转发fd读写回调登记。
- **实现**：传ptr、ctx、fd、write_handler、callback给对应vtable方法。
- **所有权 / 错误 / 调用**：不校验fd或callback，也不自动root；宿主负责持有及追踪，anyerror原样传播。

### `HostEventLoop.clearRwHandler` (`src/core/context.zig:304`)

- **签名**：`pub fn clearRwHandler(self: HostEventLoop, ctx: *JSContext, fd: i32, write_handler: bool) void`。
- **作用**：转发指定fd方向的回调清理。
- **实现**：传ptr、ctx、fd、write_handler给vtable.clearRwHandler。
- **所有权 / 错误 / 调用**：无错误返回；实际注销与值边清理由宿主实现。

### `HostEventLoop.runNextRwHandler` (`src/core/context.zig:308`)

- **签名**：`pub fn runNextRwHandler(self: HostEventLoop, ctx: *JSContext, output: ?*std.Io.Writer, global: *Object) !bool`。
- **作用**：请求宿主处理下一读写事件。
- **实现**：返回vtable.runNextRwHandler(ptr,ctx,output,global)。
- **所有权 / 错误 / 调用**：bool及anyerror原样返回；本包装不轮询fd、不调用JS、不转换异常。

### `HostEventLoop.setSignalHandler` (`src/core/context.zig:312`)

- **签名**：`pub fn setSignalHandler(self: HostEventLoop, ctx: *JSContext, sig: u32, callback: JSValue) !void`。
- **作用**：转发信号回调登记。
- **实现**：传ptr、ctx、sig和callback给vtable.setSignalHandler。
- **所有权 / 错误 / 调用**：不验证平台支持的信号或JS可调用性；宿主保存的值需追踪，anyerror传播。

### `HostEventLoop.clearSignalHandler` (`src/core/context.zig:316`)

- **签名**：`pub fn clearSignalHandler(self: HostEventLoop, ctx: *JSContext, sig: u32, disposition: SignalDisposition) void`。
- **作用**：转发信号回调清除及默认/忽略策略。
- **实现**：传ptr、ctx、sig、disposition给vtable.clearSignalHandler。
- **所有权 / 错误 / 调用**：没有错误返回；本包装不直接调用平台信号API。

### `HostEventLoop.runNextSignalHandler` (`src/core/context.zig:320`)

- **签名**：`pub fn runNextSignalHandler(self: HostEventLoop, ctx: *JSContext, output: ?*std.Io.Writer, global: *Object) !bool`。
- **作用**：请求宿主处理下一信号事件。
- **实现**：返回vtable.runNextSignalHandler(ptr,ctx,output,global)。
- **所有权 / 错误 / 调用**：bool及anyerror原样返回，不在core层额外解释、清异常或运行微任务。

## `BacktraceFrame` 辅助

### `BacktraceFrame.currentPc` (`src/core/context.zig:72`)

- **签名**：`pub fn currentPc(self: BacktraceFrame) usize`。
- **作用**：读取当前保存或间接引用的PC位置。
- **实现**：pc_source存在时读取其值并饱和减1，否则返回pc。
- **所有权 / 错误 / 调用**：不冻结或更新帧；来源为0时返回0，只有间接来源才减1。借用指针必须仍有效；与source-map行列转换分开。

### `BacktraceFrame.location` (`src/core/context.zig:76`)

- **签名**：`pub fn location(self: BacktraceFrame) BacktraceLocation`。
- **作用**：取得当前PC对应的行列。
- **实现**：先调用currentPc，再有resolver则传location_data和PC，无resolver才返回保存的line_num/col_num。
- **所有权 / 错误 / 调用**：即使无resolver也先读取pc_source；resolver结果原样返回，不校验行列或回退。回调和opaque数据须有效，无错误返回通道。

## 构造、发表、销毁

Realm 生命周期：`createConstructing*` → 填 intrinsics → `finishConstruction`/`publishLive` → 宿主 `destroy` 只丢 create-ref → 不可达后 major 调 `destroyFromHeader`。

`destroy` **不是**「立刻拆掉这个 realm」：它只消耗 host create-ref 根（TGC S1-b 删除了 `gc.release`）。heap 上的 RealmRef 边仍让 realm 活着。

### `JSContext.traceListPreviousPtr` (`src/core/context.zig:453`)

- **签名**：`pub inline fn traceListPreviousPtr(self: *JSContext) *?*gc.Header`。
- **作用**：取得布局尾洞内的可写GC链前驱槽。
- **实现**：将self地址加2168后转为*?*gc.Header。
- **所有权 / 错误 / 调用**：这是槽地址，不是当前前驱值；依赖2176字节/16对齐布局断言。普通结构赋值不保证初始化尾洞，initConstructing显式置null。

### `JSContext.traceListPreviousPtrConst` (`src/core/context.zig:457`)

- **签名**：`pub inline fn traceListPreviousPtrConst(self: *const JSContext) *const ?*gc.Header`。
- **作用**：取得同一尾洞前驱槽的只读指针。
- **实现**：将self地址加2168后转为*const ?*gc.Header。
- **所有权 / 错误 / 调用**：不读写槽，不延长context寿命；与可写版本共享布局和初始化前提。

### `JSContext.create` (`src/core/context.zig:467`)

- **签名**：`pub fn create(rt: *JSRuntime) !*JSContext`。
- **作用**：用默认选项创建并发布一个core realm。
- **实现**：委托createWithOptions(rt,.{})。
- **所有权 / 错误 / 调用**：会检查owner线程并可能分配失败；创建宿主create-ref根，调用方最终释放一次。这里不安装exec层全部标准内建或全局对象。

### `JSContext.createWithOptions` (`src/core/context.zig:473`)

- **签名**：`pub fn createWithOptions(rt: *JSRuntime, options: ContextOptions) !*JSContext`。
- **作用**：创建并立即完成core发布的realm。
- **实现**：调用createWithPublication(rt,options,true)。
- **所有权 / 错误 / 调用**：选项stack_size作用于整个runtime，而非独立realm额度；无默认全局/内建安装。成功返回指针由host create-ref保护。

### `JSContext.createConstructingWithOptions` (`src/core/context.zig:479`)

- **签名**：`pub fn createConstructingWithOptions(rt: *JSRuntime, options: ContextOptions) !*JSContext`。
- **作用**：创建已登记GC但尚未进入live枚举的realm。
- **实现**：调用createWithPublication(rt,options,false)。
- **所有权 / 错误 / 调用**：成功仍有host create-ref provider；constructing链成员资格本身不是根。外层填充后须finishConstruction，失败后也须处理宿主引用。

### `JSContext.createWithPublication` (`src/core/context.zig:483`)

- **签名**：`fn createWithPublication(rt: *JSRuntime, options: ContextOptions, publish_immediately: bool) !*JSContext`。
- **作用**：协调realm分配、初始化与可选发布。
- **实现**：先requireOwnerThread，createRuntime分配；initialized为false。initConstructing成功才置true，随后按标志finishConstruction。errdefer在未完成初始化时raw destroyRuntime，否则ctx.destroy释放宿主引用。
- **所有权 / 错误 / 调用**：WrongRuntimeThread发生于分配前。初始化已完成后的失败不承诺立即释放整realm，而按GC生命周期处理；initConstructing内部负责撤回登记和构造链等部分状态。

### `JSContext.fillNullJsValues` (`src/core/context.zig:498`)

- **签名**：`fn fillNullJsValues(values: []JSValue) void`。
- **作用**：把切片各元素写成JS null值。
- **实现**：构造一个nullValue并逐槽赋值。
- **所有权 / 错误 / 调用**：不是全字节清零或undefined初始化；不释放被覆盖值、不分配，用于新建inline原型数组。

### `JSContext.initConstructing` (`src/core/context.zig:505`)

- **签名**：`fn initConstructing(self: *JSContext, rt: *JSRuntime, options: ContextOptions) !void`。
- **作用**：建立空realm字段、原型存储、GC登记与宿主根。
- **实现**：若有stack_size先改runtime；整结构初始化并填inline null、尾洞前驱null。原型长度取classes.records.len，能放inline则借用内嵌数组，否则分配；随后登记GC、接constructing链、注册rootProvider。
- **所有权 / 错误 / 调用**：失败按逆序撤回构造链/GC登记并释放原型存储，外层释放context；之前runtime栈选项变化不回滚。provider是host create-ref根，不是构造链自动保活。self地址必须稳定，inline切片指向自身。

### `JSContext.publishLive` (`src/core/context.zig:540`)

- **签名**：`pub fn publishLive(self: *JSContext) !void`。
- **作用**：将已完成构造的realm移入live链。
- **实现**：assertOwnerThread；已live直接返回，finalizing或未construction_complete报InvalidBuiltinRegistry。注册rootProvider成功后摘constructing链、置live、接runtime live链。
- **所有权 / 错误 / 调用**：provider按context+trace去重，正常构造已注册时不会再次分配；状态转换在注册成功之后。没有检查全局对象/内建安装完整性，依赖外层构造协议。

### `JSContext.finishConstruction` (`src/core/context.zig:556`)

- **签名**：`pub fn finishConstruction(self: *JSContext) !void`。
- **作用**：标记构造完成并尝试发布。
- **实现**：assertOwnerThread；已live无操作，非constructing报InvalidBuiltinRegistry；先置construction_complete=true，再publishLive。
- **所有权 / 错误 / 调用**：若发布失败，complete标志仍为true，不回滚到false；可按协议重试。函数不构造剩余内建，仅改变标志和发布状态。

### `JSContext.finishConstructionChecked` (`src/core/context.zig:564`)

- **签名**：`pub fn finishConstructionChecked(self: *JSContext) !void`。
- **作用**：提供错误返回形式的线程检查后完成发布。
- **实现**：requireOwnerThread成功后调用finishConstruction。
- **所有权 / 错误 / 调用**：错误线程返回WrongRuntimeThread而非先触发内部panic，状态尚未改变；其他发布错误继续传播。

### `JSContext.publicationState` (`src/core/context.zig:569`)

- **签名**：`pub fn publicationState(self: *const JSContext) RealmPublicationState`。
- **作用**：读取当前发布枚举。
- **实现**：返回publication_state。
- **所有权 / 错误 / 调用**：无校验、分配或同步；它与construction_complete和host_api_release_consumed是不同字段。

### `JSContext.isLive` (`src/core/context.zig:573`)

- **签名**：`pub fn isLive(self: *const JSContext) bool`。
- **作用**：判断发布状态是否为live。
- **实现**：比较publication_state==live。
- **所有权 / 错误 / 调用**：不代表宿主create-ref仍未释放，也不重新验证realm内建完整性或GC可达性。

### `JSContext.runtimePtr` (`src/core/context.zig:577`)

- **签名**：`pub fn runtimePtr(self: *JSContext) *JSRuntime`。
- **作用**：借用realm所属runtime指针。
- **实现**：返回runtime字段。
- **所有权 / 错误 / 调用**：不创建runtime所有权或额外根，不检查owner线程；调用方遵守runtime生命周期。

### `JSContext.setStackLimit` (`src/core/context.zig:581`)

- **签名**：`pub fn setStackLimit(self: *JSContext, size: usize) void`。
- **作用**：调整所属runtime的VM栈额度。
- **实现**：委托runtime.setStackSize，更新hot.stack_size及vm_stack_arena_policy。
- **所有权 / 错误 / 调用**：影响同runtime全部realm，不是当前context专有上限；不等于setNativeStackSize，不立即重分配VM栈，本包装无线程检查。

### `JSContext.stackLimit` (`src/core/context.zig:585`)

- **签名**：`pub fn stackLimit(self: JSContext) usize`。
- **作用**：读取所属runtime的VM栈额度。
- **实现**：返回runtime.stackSize。
- **所有权 / 错误 / 调用**：按值接收context但不转移资源，读取的是runtime共享值，不是context自身字段。

## 中断轮询

`interrupt_counter_reset = 10_000`。计数器在无 handler 时仍前进/重置。cadence 命中还是 young-budget safepoint：builtin 分发漏斗必须根住 receiver/args，否则 minor 会回收正在走的对象。

### `JSContext.pollInterrupt` (`src/core/context.zig:594`)

- **签名**：`pub inline fn pollInterrupt(self: *JSContext) bool`。
- **作用**：推进realm中断节奏并在命中时执行慢路径。
- **实现**：pollInterruptTick返回false则直接false，否则pollInterruptSlow。
- **所有权 / 错误 / 调用**：返回值来自runtime处理器是否请求终止；tick命中本身不等于终止，慢路径还可能进行GC。

### `JSContext.pollInterruptTick` (`src/core/context.zig:604`)

- **签名**：`pub inline fn pollInterruptTick(self: *JSContext) bool`。
- **作用**：只推进并检查中断倒计数。
- **实现**：interrupt_counter减1，返回是否小于等于0。
- **所有权 / 错误 / 调用**：不重置计数、不调用处理器或GC；命中后调用方必须进入慢路径，不能无限只tick直到整数下溢。初始0使第一次命中。

### `JSContext.pollInterruptSlowPublic` (`src/core/context.zig:610`)

- **签名**：`pub fn pollInterruptSlowPublic(self: *JSContext) bool`。
- **作用**：公开转发慢路径。
- **实现**：直接调用pollInterruptSlow，不先tick。
- **所有权 / 错误 / 调用**：无需命中也能调用，因此会主动重置节奏并运行处理器；不是仅查询待处理中断。

### `JSContext.pollInterruptSlow` (`src/core/context.zig:614`)

- **签名**：`noinline fn pollInterruptSlow(self: *JSContext) bool`。
- **作用**：重置节奏、尝试年轻代安全点并调用runtime处理器。
- **实现**：先置10000；shouldTryMinor为真时pollGC(null,safepoint)，忽略其错误；stress_collect时再改为stress_cadence，最后runInterruptHandler。
- **所有权 / 错误 / 调用**：无处理器仍重置并可GC；GC请求不保证实际执行收集。调用方须处于可收集的安全边界，返回bool不报告被忽略的GC错误。

## 拒绝跟踪、宿主循环、prototype、shape

### `JSContext.setTrackUnhandledRejections` (`src/core/context.zig:629`)

- **签名**：`pub fn setTrackUnhandledRejections(self: *JSContext, enabled: bool) void`。
- **作用**：设置后续未处理拒绝跟踪开关。
- **实现**：直接写track_unhandled_rejections。
- **所有权 / 错误 / 调用**：不清已有队列、不补录历史拒绝、不分配，本setter无线程检查。

### `JSContext.tracksUnhandledRejections` (`src/core/context.zig:633`)

- **签名**：`pub fn tracksUnhandledRejections(self: JSContext) bool`。
- **作用**：读取拒绝跟踪开关。
- **实现**：返回track_unhandled_rejections。
- **所有权 / 错误 / 调用**：不反映当前是否有待报告拒绝，仅返回配置字段。

### `JSContext.setPreserveUncaughtException` (`src/core/context.zig:637`)

- **签名**：`pub fn setPreserveUncaughtException(self: *JSContext, enabled: bool) void`。
- **作用**：设置未捕获异常保留策略字段。
- **实现**：直接写preserve_uncaught_exception。
- **所有权 / 错误 / 调用**：不复制、清理或立即抛出异常；具体消费逻辑在外层，本setter无线程检查。

### `JSContext.preservesUncaughtException` (`src/core/context.zig:641`)

- **签名**：`pub fn preservesUncaughtException(self: JSContext) bool`。
- **作用**：读取异常保留策略字段。
- **实现**：返回preserve_uncaught_exception。
- **所有权 / 错误 / 调用**：不检查当前异常是否存在，不修改异常状态。

### `JSContext.setHostEventLoop` (`src/core/context.zig:645`)

- **签名**：`pub fn setHostEventLoop(self: *JSContext, host_event_loop: HostEventLoop) void`。
- **作用**：挂接一个宿主事件循环接口。
- **实现**：按值覆盖可选host_event_loop。
- **所有权 / 错误 / 调用**：只复制借用ptr/vtable，不销毁旧循环、不转移旧timer或主动同步根。调用方保证接口存活和正确根枚举，无内部线程检查。

### `JSContext.clearHostEventLoop` (`src/core/context.zig:649`)

- **签名**：`pub fn clearHostEventLoop(self: *JSContext, ptr: *anyopaque) void`。
- **作用**：按宿主ptr身份清除当前接口。
- **实现**：有接口且host_event_loop.ptr等于参数时置null，否则不变。
- **所有权 / 错误 / 调用**：不比较vtable、不销毁循环或清理其回调；相同ptr不同vtable仍会匹配。无分配。

### `JSContext.hostEventLoop` (`src/core/context.zig:655`)

- **签名**：`pub fn hostEventLoop(self: *JSContext) ?HostEventLoop`。
- **作用**：读取可选宿主循环接口。
- **实现**：返回host_event_loop的位拷贝。
- **所有权 / 错误 / 调用**：不增加所有权或延长ptr/vtable寿命；null表示未挂接。

### `JSContext.usingInlineClassPrototypes` (`src/core/context.zig:659`)

- **签名**：`fn usingInlineClassPrototypes(self: *const JSContext) bool`。
- **作用**：判断原型切片是否指向内嵌数组起点。
- **实现**：仅比较class_prototypes.ptr与class_prototypes_inline.ptr。
- **所有权 / 错误 / 调用**：不检查长度或值内容；零长度切片也可能属于inline，不能仅凭len==0判断存储来源。

### `JSContext.deinitClassPrototypeSlots` (`src/core/context.zig:663`)

- **签名**：`fn deinitClassPrototypeSlots(self: *JSContext) void`。
- **作用**：拆掉原型切片并按存储来源回收槽数组。
- **实现**：保存旧切片及inline判定，先置空字段，再把旧活槽写null；非inline且len非0才memory.free。
- **所有权 / 错误 / 调用**：不逐对象销毁，不释放内嵌数组；不重置所有未用inline槽。空状态可重复清理。

### `JSContext.ensureClassPrototypeSlot` (`src/core/context.zig:676`)

- **签名**：`pub fn ensureClassPrototypeSlot(self: *JSContext, class_id: class.ClassId) !*JSValue`。
- **作用**：确保class_id对应槽存在并返回可写指针。
- **实现**：assertOwnerThread；不足时按约1.5倍增长至长度大于索引，分配新数组、复制旧值并填余量null，然后换切片；旧inline活槽清null，旧外部分配释放。
- **所有权 / 错误 / 调用**：即使inline还有未用容量，也走新分配分支，不扩展inline切片。OOM保持旧存储；成功扩容使旧槽指针失效。不校验class已注册，直接写返回槽不会自动执行GC屏障。

### `JSContext.setClassPrototype` (`src/core/context.zig:700`)

- **签名**：`pub fn setClassPrototype(self: *JSContext, class_id: class.ClassId, prototype: *Object) !void`。
- **作用**：设置指定class的原型对象边。
- **实现**：ensureClassPrototypeSlot后写prototype.value，再对realm到prototype执行generationalBarrier。
- **所有权 / 错误 / 调用**：可能扩容失败；调用方保护prototype跨分配。覆盖不直接销毁旧对象，不检查prototype属于同runtime；owner检查来自ensure。

### `JSContext.clearClassPrototype` (`src/core/context.zig:711`)

- **签名**：`pub fn clearClassPrototype(self: *JSContext, class_id: class.ClassId) void`。
- **作用**：移除指定class的原型边。
- **实现**：assertOwnerThread，越界直接返回，否则写JS null。
- **所有权 / 错误 / 调用**：不缩容或销毁旧对象，无分配；重复清除不变。

### `JSContext.classPrototypeObject` (`src/core/context.zig:718`)

- **签名**：`pub fn classPrototypeObject(self: *JSContext, class_id: class.ClassId) ?*Object`。
- **作用**：借用槽内普通Object载体。
- **实现**：越界返回null，再检查isObject、refHeader存在及GC kind为object，成功Object.fromHeader。
- **所有权 / 错误 / 调用**：不把任意对象tag载体直接强转；不检查class_id是否注册，不分配或创建返回根。

### `JSContext.setNativeErrorPrototype` (`src/core/context.zig:728`)

- **签名**：`pub fn setNativeErrorPrototype(self: *JSContext, kind: NativeErrorKind, prototype: *Object) void`。
- **作用**：写入一个内建错误种类的原型边。
- **实现**：assertOwnerThread及kind!=count，直接写固定数组并调用generationalBarrier。
- **所有权 / 错误 / 调用**：无扩容，不要求对象具有特定Error品牌，不修改global上的构造器；调用方保证同runtime与有效对象。

### `JSContext.nativeErrorPrototypeObject` (`src/core/context.zig:736`)

- **签名**：`pub fn nativeErrorPrototypeObject(self: *JSContext, kind: NativeErrorKind) ?*Object`。
- **作用**：读取内建错误原型槽中的Object。
- **实现**：count哨兵返回null；其余检查对象tag、header及object kind后还原指针。
- **所有权 / 错误 / 调用**：不创建或修复缺失原型，不增加根或引用数。

### `JSContext.initializeInitialShapes` (`src/core/context.zig:745`)

- **签名**：`pub fn initializeInitialShapes( self: *JSContext, object_prototype: ?*Object, array_prototype: ?*Object, regexp_prototype: ?*Object, ) !void`。
- **作用**：一次建立五个realm初始shape缓存。
- **实现**：array_shape已有值即返回；否则断言其余四槽空。依次建立array空属性shape、arguments与mapped arguments的length/iterator/callee、regexp的lastIndex、regexp结果的index/input/groups；全部成功后才写五槽。heap_accounted时对五条边执行屏障。
- **所有权 / 错误 / 调用**：普通arguments的callee为不可枚举不可配置accessor，mapped callee为可写不可枚举可配置data；lastIndex可写不可枚举不可配置，结果三属性全true。array和结果shape不含length普通属性。失败不发布部分realm槽，但此前已成功创建的shape没有本函数errdefer立即回收，不能声称整批同步释放；后续靠其GC生命周期。早退不比较新传prototype。

### `JSContext.releaseInitialShape` (`src/core/context.zig:811`)

- **签名**：`fn releaseInitialShape(self: *JSContext, slot: *?*shape.Shape) void`。
- **作用**：移除一条初始shape边并尝试直接回收未共享shape。
- **实现**：槽空返回，否则先置null，再runtime.shapes.dropUnshared。
- **所有权 / 错误 / 调用**：dropUnshared在shared、GC deinit或已condemned时不立即销毁；不是无条件free或引用计数release。

### `JSContext.clearIntrinsicBootstrapValues` (`src/core/context.zig:818`)

- **签名**：`fn clearIntrinsicBootstrapValues(self: *JSContext) void`。
- **作用**：清空内建启动缓存并释放初始shape持有关系。
- **实现**：eval_function置JS null，函数/Promise原型缓存及cached_values置空，native_error_prototypes填JS null；逐清五个shape，最后preallocated_oom_error置空。
- **所有权 / 错误 / 调用**：不清global、lexicals、class_prototypes或宿主循环；多数值仅移除边，shape可能立即回收。不是完整realm销毁。

### `JSContext.rollbackIntrinsicBootstrap` (`src/core/context.zig:841`)

- **签名**：`pub fn rollbackIntrinsicBootstrap(self: *JSContext) void`。
- **作用**：撤回一次内建启动写入的缓存与标准class原型前缀。
- **实现**：assertOwnerThread、非finalizing且lexicals/regexp statics为空；清启动缓存，再将class原型前min(len,init_count)槽置null。constructing时construction_complete置false。
- **所有权 / 错误 / 调用**：保留动态class原型后缀、global关联、原型数组容量和其他realm状态；不销毁候选global，也不把live状态改回constructing。不是整个realm的事务回滚。

### `JSContext.deinitResources` (`src/core/context.zig:854`)

- **签名**：`fn deinitResources(self: *JSContext) void`。
- **作用**：在GC终结时拆除realm资源。
- **实现**：assertOwnerThread；constructing只摘构造链，live摘live链并注销provider，finalizing不可再次进入。置finalizing后摘模块成员、清loop/rejections/global/lexicals/内建缓存、销毁regexp statics及原型槽存储。
- **所有权 / 错误 / 调用**：constructing分支不在此注销provider，不能泛称所有分支都注销；收集器调用须满足根生命周期前提。模块/JS对象主要移除边，不递归释放；host loop仅置空，不调用宿主析构。

### `JSContext.destroy` (`src/core/context.zig:886`)

- **签名**：`pub fn destroy(self: *JSContext) void`。
- **作用**：消费一次宿主create-ref。
- **实现**：assertOwnerThread后consumeHostApiRelease。
- **所有权 / 错误 / 调用**：不立即销毁realm、不摘live链、不清全局或模块；可达堆边仍保持realm。宿主只调用一次，释放后裸指针不能脱离其他可达引用继续使用。

### `JSContext.tryDestroy` (`src/core/context.zig:893`)

- **签名**：`pub fn tryDestroy(self: *JSContext) runtime_mod.RuntimeMutationError!void`。
- **作用**：以错误返回形式检查线程后消费宿主引用。
- **实现**：requireOwnerThread成功后consumeHostApiRelease。
- **所有权 / 错误 / 调用**：错线程返回WrongRuntimeThread且不改释放标志/根；不是重复destroy的容错接口，已消费仍违反断言。

### `JSContext.consumeHostApiRelease` (`src/core/context.zig:898`)

- **签名**：`fn consumeHostApiRelease(self: *JSContext) void`。
- **作用**：记录宿主引用已消费并移除其根提供器。
- **实现**：断言host_api_release_consumed为false，置true，再dropHostRootProvider。
- **所有权 / 错误 / 调用**：不修改publication_state或GC堆边。无引用计数递减；关闭断言也不使重复使用已回收指针合法。

### `JSContext.dropHostRootProvider` (`src/core/context.zig:909`)

- **签名**：`fn dropHostRootProvider(self: *JSContext) void`。
- **作用**：按发布状态移除host provider。
- **实现**：constructing/live调用unregisterRootProvider；finalizing不操作。
- **所有权 / 错误 / 调用**：不改变host_api_release_consumed，不注销其他持有者的根，也不清realm字段。

### `JSContext.destroyFromHeader` (`src/core/context.zig:916`)

- **签名**：`pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void`。
- **作用**：执行realm资源终结并释放context存储。
- **实现**：检查传入runtime owner线程，从header还原self，调用deinitResources后rt.destroyRuntime。
- **所有权 / 错误 / 调用**：无第二阶段延迟，不在此摘GC登记；调用方保证header与runtime身份正确及GC销毁协议，非宿主destroy替代品。

## 句柄、根、异常、rejection、backtrace

### `JSContext.createValueHandle` (`src/core/context.zig:924`)

- **签名**：`pub fn createValueHandle(self: *JSContext, value: JSValue) !runtime_mod.JSValueHandle`。
- **作用**：为value创建所属runtime的持久根句柄。
- **实现**：委托runtime.createValueHandle，再进入JSValueHandle.initDup。
- **所有权 / 错误 / 调用**：不复制JS对象；tracing下initDup委托init创建独立根槽。分配错误由底层传播，此路径不做owner线程检查，调用方须遵守runtime线程约束；成功句柄最终由调用方deinit。

### `JSContext.takeValueHandle` (`src/core/context.zig:928`)

- **签名**：`pub fn takeValueHandle(self: *JSContext, value: JSValue) !runtime_mod.JSValueHandle`。
- **作用**：为value建立持久根句柄。
- **实现**：委托runtime.takeValueHandle，进入JSValueHandle.init。
- **所有权 / 错误 / 调用**：同样是值位拷贝加根槽，不销毁输入对象；失败时没有成功句柄，不能假定输入已经被新根保护。

### `JSContext.traceRoots` (`src/core/context.zig:932`)

- **签名**：`pub fn traceRoots(self: *JSContext, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：在live状态枚举realm的根接口字段。
- **实现**：非live直接返回；按配置枚举模块及五shape，始终访问拒绝条目、eval/oom值、原型、缓存、regexp静态值、global/lexicals及host loop。缓存对象通过局部optional指针访问后写回。
- **所有权 / 错误 / 调用**：本函数不检查host_api_release_consumed，也不访问realm自身header；该检查/访问由traceRootProvider承担。visitor错误立即传播且可留下已更新字段；不枚举runtime/构造链链接。

### `JSContext.traceChildEdgesNoFail` (`src/core/context.zig:985`)

- **签名**：`pub fn traceChildEdgesNoFail(self: *JSContext, visitor: anytype) void`。
- **作用**：以无错误回调枚举realm的堆子边。
- **实现**：仅finalizing跳过，constructing也可遍历；模块、所有值/原型、五shape、regexp静态值及global/lexicals逐项交visitor。
- **所有权 / 错误 / 调用**：不访问host_event_loop或runtime/构造链，也不受traceRoots中shape配置条件限制。直接visitValue/Object/Shape要求visitor实现相应方法；模块适配另有可选visitModule规则。不是现行RC引用计数接口。

### `JSContext.arrayBuffer` (`src/core/context.zig:1016`)

- **签名**：`pub fn arrayBuffer(self: *JSContext, store: *JSValue.Bytes.Store) !JSValue`。
- **作用**：委托字节Store构造ArrayBuffer或SharedArrayBuffer值。
- **实现**：调用store.toArrayBuffer(self)，共享标志决定底层分支；成功后Store被disarm。
- **所有权 / 错误 / 调用**：缺deinit回调报InvalidStore，构造/安装错误传播。共享分支的失败资源责任须遵守bytes_view.Store具体实现，不能一概承诺失败完全不消费；详见06的Store说明。

### `JSContext.rootProvider` (`src/core/context.zig:1020`)

- **签名**：`fn rootProvider(self: *JSContext) runtime_mod.RootProvider`。
- **作用**：构造宿主根提供器描述。
- **实现**：返回context=self及trace=traceRootProvider。
- **所有权 / 错误 / 调用**：仅返回借用指针与函数，不在此注册或延长寿命；runtime以两字段配对去重/注销。

### `JSContext.traceRootProvider` (`src/core/context.zig:1027`)

- **签名**：`fn traceRootProvider(context: *anyopaque, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：从仍有效的宿主create-ref追踪realm。
- **实现**：将opaque context还原self；若host_api_release_consumed则返回，否则先visitor.constHeader，再self.traceRoots。
- **所有权 / 错误 / 调用**：constructing时仍提交realm header，但traceRoots会跳过直接字段枚举；header后续子边遍历负责其边。错误传播，不使用context列表成员资格作为根。

### `JSContext.throwValue` (`src/core/context.zig:1037`)

- **签名**：`pub fn throwValue(self: *JSContext, value: JSValue) JSValue`。
- **作用**：替换runtime共享的挂起异常并返回异常哨兵。
- **实现**：先将current_exception写uninitialized，清uncatchable/OOM标志，再存value并返回JSValue.exception。
- **所有权 / 错误 / 调用**：不是Zig error返回或立即栈展开；所有同runtime context共享该槽。不验证输入为Error对象、不构造消息/回溯、不显式释放旧异常。

### `JSContext.setExceptionUncatchable` (`src/core/context.zig:1045`)

- **签名**：`pub fn setExceptionUncatchable(self: *JSContext, uncatchable: bool) void`。
- **作用**：设置共享挂起异常的不可捕获标志。
- **实现**：断言设置true时hasException，再写runtime标志。
- **所有权 / 错误 / 调用**：设置false不要求有异常；不改变异常值，也不触发抛出。

### `JSContext.exceptionIsUncatchable` (`src/core/context.zig:1050`)

- **签名**：`pub fn exceptionIsUncatchable(self: JSContext) bool`。
- **作用**：检查当前异常及不可捕获标志。
- **实现**：返回hasException() and current_exception_uncatchable。
- **所有权 / 错误 / 调用**：没有异常时即使残留标志为true也返回false，读取runtime共享状态。

### `JSContext.markExceptionOutOfMemory` (`src/core/context.zig:1057`)

- **签名**：`pub fn markExceptionOutOfMemory(self: *JSContext) void`。
- **作用**：给已挂起异常添加OOM分类标志。
- **实现**：断言hasException，写current_exception_out_of_memory=true。
- **所有权 / 错误 / 调用**：不检查异常品牌或文本；应在throwValue后调用，因为throwValue会清标志。

### `JSContext.exceptionIsOutOfMemory` (`src/core/context.zig:1062`)

- **签名**：`pub fn exceptionIsOutOfMemory(self: JSContext) bool`。
- **作用**：读取当前异常是否带OOM标志。
- **实现**：返回hasException() and current_exception_out_of_memory。
- **所有权 / 错误 / 调用**：不根据消息内容推断，也不主动清除标志。

### `JSContext.hasException` (`src/core/context.zig:1066`)

- **签名**：`pub fn hasException(self: JSContext) bool`。
- **作用**：判断runtime异常槽是否已设置。
- **实现**：返回!current_exception.isUninitialized()。
- **所有权 / 错误 / 调用**：使用内部uninitialized哨兵而非undefined；throw undefined仍算有异常。状态跨同runtime的realm共享。

### `JSContext.takeException` (`src/core/context.zig:1070`)

- **签名**：`pub fn takeException(self: *JSContext) JSValue`。
- **作用**：取出并清除当前挂起异常。
- **实现**：无异常返回undefined且不写其他字段；有异常保存值、槽置uninitialized、清两个标志后返回。
- **所有权 / 错误 / 调用**：返回值与真实throw undefined不可单凭结果区分；需预先hasException。不建立返回值根，调用方接手保护。

### `JSContext.clearException` (`src/core/context.zig:1079`)

- **签名**：`pub fn clearException(self: *JSContext) void`。
- **作用**：清空runtime异常值及两个分类标志。
- **实现**：槽置uninitialized，uncatchable/OOM均置false。
- **所有权 / 错误 / 调用**：不返回或显式销毁旧值，不清未处理拒绝列表或回溯；无线程检查。

### `JSContext.recordUnhandledRejection` (`src/core/context.zig:1085`)

- **签名**：`pub fn recordUnhandledRejection(self: *JSContext, value: JSValue) void`。
- **作用**：记录没有Promise身份的拒绝原因。
- **实现**：委托recordUnhandledPromiseRejection(null,value)。
- **所有权 / 错误 / 调用**：不按reason去重，也不在此检查track_unhandled_rejections开关；成功可能设置runtime挂起异常。

### `JSContext.recordUnhandledPromiseRejection` (`src/core/context.zig:1095`)

- **签名**：`pub fn recordUnhandledPromiseRejection(self: *JSContext, promise: ?JSValue, value: JSValue) void`。
- **作用**：按可选Promise身份追加拒绝记录。
- **实现**：有promise时用JSValue.same扫描，已存在立即返回；否则append，错误直接丢弃。成功且runtime没有异常时throwValue(reason)。
- **所有权 / 错误 / 调用**：不检查Promise品牌或跟踪开关，开关判断由调用方负责。重复身份不更新reason；OOM不新增记录也不安装异常，已有异常不会被覆盖。

### `JSContext.appendUnhandledRejection` (`src/core/context.zig:1107`)

- **签名**：`fn appendUnhandledRejection(self: *JSContext, promise: ?JSValue, value: JSValue) !void`。
- **作用**：向realm拒绝列表追加一个条目。
- **实现**：容量不足从4或两倍增长，分配复制旧项后替换并释放旧块；追加promise或undefined及reason。
- **所有权 / 错误 / 调用**：失败保留旧列表；无显式GC写屏障，输入跨分配需由外层保护。容量算术非checked OOM；成功增长使旧元素指针失效。

### `JSContext.removeUnhandledPromiseRejection` (`src/core/context.zig:1131`)

- **签名**：`pub fn removeUnhandledPromiseRejection(self: *JSContext, promise_value: JSValue) void`。
- **作用**：删除首个匹配Promise身份的条目。
- **实现**：线性same比较，命中用memmove前移尾项并缩短长度。
- **所有权 / 错误 / 调用**：不按reason删除，不缩容、不清废弃尾槽，也不清runtime挂起异常；不直接销毁JS对象。

### `JSContext.hasUnhandledRejection` (`src/core/context.zig:1144`)

- **签名**：`pub fn hasUnhandledRejection(self: JSContext) bool`。
- **作用**：检查拒绝列表是否非空。
- **实现**：返回unhandled_rejections.len!=0。
- **所有权 / 错误 / 调用**：不参考跟踪开关或runtime异常，不报告是否已输出日志。

### `JSContext.takeUnhandledRejection` (`src/core/context.zig:1151`)

- **签名**：`pub fn takeUnhandledRejection(self: *JSContext) JSValue`。
- **作用**：移出最早记录并返回其reason。
- **实现**：空时返回undefined，否则复制首项、memmove后续项并缩短列表，返回reason。
- **所有权 / 错误 / 调用**：O(n)，不缩容或清尾槽、不返回Promise身份、不清runtime异常。undefined也可能是真实reason，需hasUnhandledRejection区分；返回值不另建根。

### `JSContext.clearUnhandledRejection` (`src/core/context.zig:1162`)

- **签名**：`pub fn clearUnhandledRejection(self: *JSContext) void`。
- **作用**：清空拒绝记录并释放整个backing。
- **实现**：先保存切片/容量并清字段，capacity非0时按完整容量free。
- **所有权 / 错误 / 调用**：不逐对象析构，不清runtime异常或跟踪开关；重复清理空列表可行。

### `JSContext.classPrototypeSlotCount` (`src/core/context.zig:1171`)

- **签名**：`pub fn classPrototypeSlotCount(self: JSContext) usize`。
- **作用**：读取当前可索引的class原型槽数。
- **实现**：返回class_prototypes.len。
- **所有权 / 错误 / 调用**：包含扩容产生的空槽，不等于已注册class数或非空原型数。

### `JSContext.pushBacktraceFrame` (`src/core/context.zig:1175`)

- **签名**：`pub fn pushBacktraceFrame( self: *JSContext, function_name: atom.Atom, filename: atom.Atom, line_num: i32, col_num: i32, ) !void`。
- **作用**：追加不带位置resolver的持久回溯帧。
- **实现**：委托pushBacktraceFrameWithResolver，data和resolver均null。
- **所有权 / 错误 / 调用**：帧存于runtime共享数组；可能分配失败，本入口不绑定活PC。

### `JSContext.pushBacktraceFrameWithResolver` (`src/core/context.zig:1185`)

- **签名**：`pub fn pushBacktraceFrameWithResolver( self: *JSContext, function_name: atom.Atom, filename: atom.Atom, line_num: i32, col_num: i32, location_data: ?*const anyopaque, location_resolver: ?BacktraceLocationResolver, ) !void`。
- **作用**：追加带可选位置resolver的持久帧。
- **实现**：委托LazyName版本，function_value传undefined。
- **所有权 / 错误 / 调用**：不立即解析行列或函数名；借用location_data/resolver，调用方保证寿命。分配错误传播。

### `JSContext.pushActiveBacktraceFrame` (`src/core/context.zig:1197`)

- **签名**：`pub fn pushActiveBacktraceFrame(self: *JSContext, frame: *ActiveBacktraceFrame) void`。
- **作用**：把外部活帧组节点挂到runtime栈顶。
- **实现**：frame.previous接当前栈顶，再写current_backtrace_frame。
- **所有权 / 错误 / 调用**：无分配或防重复插入检查；节点/数据必须保持地址与寿命，调用方按LIFO撤回，不能让同节点重复成环。

### `JSContext.popActiveBacktraceFrame` (`src/core/context.zig:1202`)

- **签名**：`pub fn popActiveBacktraceFrame(self: *JSContext, frame: *ActiveBacktraceFrame) void`。
- **作用**：按LIFO摘掉给定活帧组节点。
- **实现**：断言当前栈顶为frame，恢复previous，再清frame.previous。
- **所有权 / 错误 / 调用**：不销毁节点或data，不更改持久帧数组；调用方不得越序pop。

### `JSContext.snapshotBacktraceFrames` (`src/core/context.zig:1208`)

- **签名**：`pub fn snapshotBacktraceFrames(self: *JSContext) ![]BacktraceFrame`。
- **作用**：将持久帧与当前活帧组复制为可释放数组。
- **实现**：先调用resolver逐组计数，barrier帧自身及之后活帧均排除；总数0返回空片段。分配后先复制持久帧，再第二遍解析活组并反向写入，使最内层位于数组末端。
- **所有权 / 错误 / 调用**：resolver调用两遍，调用方须保证帧数量/顺序稳定；没有内部锁或二次数量复核。barrier不剔除持久帧前缀。PC冻结但opaque位置数据仍借用，数组本身不自动注册GC根，atom/函数值及数据寿命由持有方保证。

### `JSContext.freeBacktraceFrameSnapshot` (`src/core/context.zig:1253`)

- **签名**：`pub fn freeBacktraceFrameSnapshot(self: *JSContext, frames: []BacktraceFrame) void`。
- **作用**：释放快照数组存储。
- **实现**：非空数组交runtime.memory.free（RC 时代逐帧释放留下的空循环已删）。
- **所有权 / 错误 / 调用**：不逐atom/函数值release、不清调用方切片，不允许重复释放非空数组；须匹配创建快照的账户。

### `JSContext.dupBacktraceFrame` (`src/core/context.zig:1257`)

- **签名**：`fn dupBacktraceFrame(self: *JSContext, frame: BacktraceFrame) BacktraceFrame`。
- **作用**：复制持久帧并冻结其当前PC。
- **实现**：两个atom经noteHolderStore，pc取currentPc，保留行列/data/resolver/is_native；function_value仅对象tag保留，其余undefined，pc_source默认null。
- **所有权 / 错误 / 调用**：不解析位置或惰性显示名、不深拷贝data；atom记录/屏障不是引用计数，新帧仍需可达持有者。

### `JSContext.dupActiveBacktraceFrameFromSnapshot` (`src/core/context.zig:1271`)

- **签名**：`fn dupActiveBacktraceFrameFromSnapshot(self: *JSContext, snapshot: ActiveBacktraceSnapshot) BacktraceFrame`。
- **作用**：从活帧快照构造BacktraceFrame。
- **实现**：记录两个atom，复制pc/行列/data/resolver/is_native，仅保留对象function_value；pc_source默认null。
- **所有权 / 错误 / 调用**：不将backtrace_barrier存入结果，调用方在遍历时处理它；位置resolver数据仍借用，不自动成为持久根。

### `JSContext.pushBacktraceFrameLazyName` (`src/core/context.zig:1288`)

- **签名**：`pub fn pushBacktraceFrameLazyName( self: *JSContext, function_name: atom.Atom, filename: atom.Atom, line_num: i32, col_num: i32, location_data: ?*const anyopaque, location_resolver: ?BacktraceLocationResolver, function_value: JSValue, ) !void`。
- **作用**：保存带惰性函数名来源的持久帧。
- **实现**：数组满时从16或两倍容量分配复制并释放旧块；非对象function_value改undefined，两个atom经noteHolderStore，写新帧后增长长度。
- **所有权 / 错误 / 调用**：此处不解析名称；pc默认0、pc_source默认null、is_native默认false。失败发生在追加前，输入跨分配由调用方保护，成功扩容会使旧帧地址失效。

### `JSContext.popBacktraceFrame` (`src/core/context.zig:1322`)

- **签名**：`pub fn popBacktraceFrame(self: *JSContext) void`。
- **作用**：移除最后一个持久回溯帧。
- **实现**：空数组无操作，否则仅长度减1。
- **所有权 / 错误 / 调用**：不释放容量或清旧槽，不更改活帧链；被移出的JS值/atom不再由活长度表示持有。

### `JSContext.updateBacktracePc` (`src/core/context.zig:1328`)

- **签名**：`pub fn updateBacktracePc(self: *JSContext, pc: usize) void`。
- **作用**：更新最后持久帧的固定PC。
- **实现**：无帧返回，否则pc_source置null并写pc。
- **所有权 / 错误 / 调用**：不改变位置resolver/data或保存行列，不操作活帧组。

### `JSContext.borrowBacktracePc` (`src/core/context.zig:1335`)

- **签名**：`pub fn borrowBacktracePc(self: *JSContext, pc_source: *const usize) void`。
- **作用**：使最后持久帧借用活PC计数器。
- **实现**：无帧返回，否则将pc_source写为参数指针。
- **所有权 / 错误 / 调用**：不冻结当前数值，不清备用pc；之后currentPc读来源并减1，来源必须保持有效。

### `JSContext.updateBacktraceLocation` (`src/core/context.zig:1340`)

- **签名**：`pub fn updateBacktraceLocation(self: *JSContext, pc: usize, line_num: i32, col_num: i32) void`。
- **作用**：更新最后持久帧固定PC与保存行列。
- **实现**：无帧返回，否则清pc_source并写pc、line_num、col_num。
- **所有权 / 错误 / 调用**：不清location_resolver/data；若仍有resolver，location()仍优先采用resolver结果，而非这两个保存字段。

### `JSContext.takePendingException` (`src/core/context.zig:1349`)

- **签名**：`pub fn takePendingException(self: *JSContext) JSValue`。
- **作用**：优先取出最早拒绝原因，否则取runtime异常。
- **实现**：有拒绝则takeUnhandledRejection，若runtime有异常则clearException，再返回拒绝；无拒绝才takeException。
- **所有权 / 错误 / 调用**：即便runtime挂起的是不同异常，也会在拒绝分支清掉；不是两个来源独立保留。返回值不另建根。

### `JSContext.globalObject` (`src/core/context.zig:1358`)

- **签名**：`pub fn globalObject(self: *JSContext) !*Object`。
- **作用**：返回已有global或调用runtime物化钩子。
- **实现**：self.global非null直接返回；否则存在materialize_context_global_cb便调用，无钩子报InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：本函数不自行缓存钩子结果、验证realm状态或安装内建；这些责任在具体回调，错误原样传播。

## `RealmRef`

`RealmContext = JSContext`。`RealmRef` 是 `extern struct { ptr: ?*RealmContext }`，大小等于可选指针。Runtime 列表 membership **不**表示在这里。

### `RealmRef.takeOwned` (`src/core/context.zig:1381`)

- **签名**：`pub fn takeOwned(ctx: *RealmContext) RealmRef`。
- **作用**：把宿主create-ref转换为普通realm指针边。
- **实现**：ctx.consumeHostApiRelease后返回ptr=ctx。
- **所有权 / 错误 / 调用**：撤销宿主根而不新建根；调用方必须把结果放入可追踪持有者，不能把裸结构当Persistent句柄。不能重复消费同一host引用。

### `RealmRef.retain` (`src/core/context.zig:1389`)

- **签名**：`pub fn retain(ctx: *RealmContext) RealmRef`。
- **作用**：构造指向realm的普通引用边。
- **实现**：返回ptr=ctx。
- **所有权 / 错误 / 调用**：名称沿用retain但没有计数或根注册；只有可达持有者实际追踪此边才保活。无分配，不消费host create-ref。

### `RealmRef.clone` (`src/core/context.zig:1393`)

- **签名**：`pub fn clone(self: RealmRef) RealmRef`。
- **作用**：按值复制realm引用边。
- **实现**：直接返回self。
- **所有权 / 错误 / 调用**：没有引用计数增量或独立根；复制结果需要自己的可达持有者。空引用仍为空。

### `RealmRef.borrow` (`src/core/context.zig:1397`)

- **签名**：`pub fn borrow(self: RealmRef) ?*RealmContext`。
- **作用**：读取可选realm指针。
- **实现**：返回ptr。
- **所有权 / 错误 / 调用**：不验证对象存活或线程，不延长寿命；null只表示此引用为空。

### `RealmRef.deinit` (`src/core/context.zig:1401`)

- **签名**：`pub fn deinit(self: *RealmRef) void`。
- **作用**：清空该realm引用边。
- **实现**：ptr置null。
- **所有权 / 错误 / 调用**：不调用ctx.destroy、不回收realm或递减计数；重复清空可行，不影响其他副本。

## 覆盖核对

- 清单函数数: 106
- 本文标题覆盖: 106
- 未覆盖: 无
